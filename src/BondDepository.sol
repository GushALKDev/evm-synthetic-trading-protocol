// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ISynthToken} from "./interfaces/ISynthToken.sol";

/**
 * @title BondDepository
 * @author GushALKDev
 * @notice Layer 3 of the solvency system: sells $SYNTH at a discount for USDC during recapitalization
 *         rounds. The raised USDC is injected straight into the Vault; the discounted $SYNTH is vested
 *         to bonders linearly over a configurable window.
 * @dev A round is opened only by the SolvencyManager via activateBonding(neededUsdc), which sets the
 *      remaining cap for that round. Bonders call bond(usdcAmount) until the cap is exhausted, at which
 *      point the round auto-closes. $SYNTH is priced off a keeper-maintained referencePrice (USDC per
 *      SYNTH, proxy for a TWAP) with a capped discount.
 *
 *      Vesting rationale (PoC): the sell-side discount makes an instant "bond → dump on market" a
 *      near risk-free arbitrage that pushes the token price down, and — since bonds re-price against
 *      that same referencePrice — can feed on itself (the classic OlympusDAO bond-and-dump). Linear
 *      vesting over VESTING_PERIOD breaks the *atomic* arbitrage (buy and sell in one tx) and spreads
 *      any sell pressure across time instead of a single dump, at the cost of making bonds less
 *      attractive during an acute crisis. VESTING_PERIOD is owner-configurable (default 48h, capped at
 *      MAX_VESTING_PERIOD) so it can be shortened to raise capital faster or lengthened if the token
 *      is under pressure. A real DEX TWAP oracle and a debt-ratio-based dynamic discount are V2 work.
 */
contract BondDepository is Ownable {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_DISCOUNT_BPS = 1_000; // 10% ceiling (doc: 5-10%)
    uint256 public constant MAX_VESTING_PERIOD = 7 days; // doc: 0-7 days

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable ASSET; // USDC (6 decimals)
    address public immutable VAULT;
    ISynthToken public immutable SYNTH;

    address public solvencyManager;

    /**
     * @notice Reference price of $SYNTH in USDC (6 decimals) per 1 SYNTH (WAD), proxy for a TWAP
     */
    uint256 public referencePrice;

    /**
     * @notice Discount applied to the reference price when pricing bonds, in BPS
     */
    uint256 public discountBps;

    /**
     * @notice Linear vesting window applied to each bond, in seconds
     */
    uint256 public vestingPeriod;

    /**
     * @notice Remaining USDC that can still be raised in the active round (0 == no active round)
     */
    uint256 public remainingCap;

    /**
     * @notice A bonder's vesting position for a single bond purchase
     * @dev totalSynth minted to this contract at bond time; released linearly from start to end.
     */
    struct BondPosition {
        uint128 totalSynth; // total $SYNTH owed to the bonder
        uint128 claimedSynth; // $SYNTH already claimed
        uint64 start; // vesting start timestamp
        uint64 end; // vesting end timestamp
    }

    /**
     * @notice Vesting positions per bonder (a bonder may hold several simultaneous bonds)
     */
    mapping(address => BondPosition[]) private _bonds;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event BondingActivated(uint256 neededUsdc);
    event Bonded(address indexed bonder, uint256 bondId, uint256 usdcIn, uint256 synthOut, uint256 vestingEnd);
    event Claimed(address indexed bonder, uint256 bondId, uint256 synthClaimed);
    event RoundClosed();
    event SolvencyManagerUpdated(address indexed newSolvencyManager);
    event ReferencePriceUpdated(uint256 newReferencePrice);
    event DiscountUpdated(uint256 newDiscountBps);
    event VestingPeriodUpdated(uint256 newVestingPeriod);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error CallerNotSolvencyManager();
    error SolvencyManagerNotSet();
    error DiscountTooHigh(uint256 discountBps);
    error VestingPeriodTooLong(uint256 vestingPeriod);
    error ReferencePriceUnset();
    error NoActiveRound();
    error RoundAlreadyActive();
    error InvalidBondId(uint256 bondId);
    error NothingToClaim();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlySolvencyManager() {
        _requireSolvencyManager();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireSolvencyManager() internal view {
        if (solvencyManager == address(0)) revert SolvencyManagerNotSet();
        if (msg.sender != solvencyManager) revert CallerNotSolvencyManager();
    }

    /**
     * @dev $SYNTH vested for a position at the current timestamp (linear from start to end)
     */
    function _vested(BondPosition storage _pos) internal view returns (uint256) {
        if (block.timestamp >= _pos.end) return _pos.totalSynth;
        if (block.timestamp <= _pos.start) return 0;
        uint256 elapsed = block.timestamp - _pos.start;
        uint256 duration = _pos.end - _pos.start;
        return (uint256(_pos.totalSynth) * elapsed) / duration;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _asset, address _vault, address _synth, uint256 _discountBps, address _owner) {
        if (_asset == address(0) || _vault == address(0) || _synth == address(0)) revert ZeroAddress();
        if (_discountBps > MAX_DISCOUNT_BPS) revert DiscountTooHigh(_discountBps);
        _initializeOwner(_owner);
        ASSET = _asset;
        VAULT = _vault;
        SYNTH = ISynthToken(_synth);
        discountBps = _discountBps;
        referencePrice = 2 * 10 ** 6; // Default: 2 USDC per SYNTH
        vestingPeriod = 48 hours; // Default linear vesting window
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Open a bonding round to raise up to `_neededUsdc` for the Vault
     * @dev Only the SolvencyManager may call. Reverts if a round is already active or price is unset.
     * @param _neededUsdc Target USDC to raise in this round (the round cap)
     */
    function activateBonding(uint256 _neededUsdc) external onlySolvencyManager {
        if (_neededUsdc == 0) revert ZeroAmount();
        if (remainingCap != 0) revert RoundAlreadyActive();
        if (referencePrice == 0) revert ReferencePriceUnset();

        remainingCap = _neededUsdc;
        emit BondingActivated(_neededUsdc);
    }

    /**
     * @notice Buy discounted $SYNTH by depositing USDC; the USDC is injected into the Vault
     * @dev Permissionless. USDC is pulled from the caller and sent to the Vault; the discounted $SYNTH
     *      is minted to this contract and vested to the caller linearly over vestingPeriod (claimed
     *      via claim). The deposit is clamped to the remaining round cap; the round closes when the cap
     *      is exhausted. CEI: state (cap, position) updated before external mint/transfers.
     * @param _usdcAmount USDC the caller wishes to bond (clamped to remainingCap)
     * @return bondId Index of the created vesting position for msg.sender
     * @return synthOut Amount of $SYNTH vesting to the caller
     */
    function bond(uint256 _usdcAmount) external returns (uint256 bondId, uint256 synthOut) {
        if (_usdcAmount == 0) revert ZeroAmount();
        uint256 cap = remainingCap;
        if (cap == 0) revert NoActiveRound();

        // Checks / Effects
        uint256 usdcIn = _usdcAmount > cap ? cap : _usdcAmount;
        synthOut = quoteBond(usdcIn);
        uint256 newCap = cap - usdcIn;
        remainingCap = newCap;

        uint64 start = uint64(block.timestamp);
        uint64 end = uint64(block.timestamp + vestingPeriod);
        bondId = _bonds[msg.sender].length;
        _bonds[msg.sender].push(BondPosition({totalSynth: uint128(synthOut), claimedSynth: 0, start: start, end: end}));

        // Interactions: USDC to Vault, $SYNTH minted into this contract's custody for vesting
        ASSET.safeTransferFrom(msg.sender, VAULT, usdcIn);
        SYNTH.mint(address(this), synthOut);
        emit Bonded(msg.sender, bondId, usdcIn, synthOut, end);

        if (newCap == 0) emit RoundClosed();
    }

    /**
     * @notice Claim the vested-so-far $SYNTH from one of the caller's bonds
     * @dev CEI: claimed amount recorded before the token transfer.
     * @param _bondId Index of the caller's bond position
     * @return claimed $SYNTH transferred to the caller
     */
    function claim(uint256 _bondId) external returns (uint256 claimed) {
        BondPosition[] storage positions = _bonds[msg.sender];
        if (_bondId >= positions.length) revert InvalidBondId(_bondId);

        BondPosition storage pos = positions[_bondId];
        claimed = _vested(pos) - pos.claimedSynth;
        if (claimed == 0) revert NothingToClaim();

        pos.claimedSynth += uint128(claimed);
        address(SYNTH).safeTransfer(msg.sender, claimed);
        emit Claimed(msg.sender, _bondId, claimed);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Amount of $SYNTH received for `_usdcAmount` at the current discounted price
     * @dev synthOut = usdcIn * WAD / (referencePrice * (1 - discount)). The discount lowers the
     *      effective price, so the bonder receives more SYNTH per USDC.
     * @param _usdcAmount USDC input (6 decimals)
     * @return synthOut $SYNTH output (18 decimals)
     */
    function quoteBond(uint256 _usdcAmount) public view returns (uint256 synthOut) {
        uint256 effectivePrice = (referencePrice * (BPS_DENOMINATOR - discountBps)) / BPS_DENOMINATOR;
        return (_usdcAmount * WAD) / effectivePrice;
    }

    /**
     * @notice Whether a bonding round is currently open
     */
    function isActive() external view returns (bool) {
        return remainingCap != 0;
    }

    /**
     * @notice Number of bond positions a bonder holds
     */
    function bondCount(address _bonder) external view returns (uint256) {
        return _bonds[_bonder].length;
    }

    /**
     * @notice A bonder's bond position
     */
    function bondAt(address _bonder, uint256 _bondId) external view returns (BondPosition memory) {
        if (_bondId >= _bonds[_bonder].length) revert InvalidBondId(_bondId);
        return _bonds[_bonder][_bondId];
    }

    /**
     * @notice $SYNTH currently claimable from a bonder's position (vested minus already claimed)
     */
    function claimable(address _bonder, uint256 _bondId) external view returns (uint256) {
        if (_bondId >= _bonds[_bonder].length) revert InvalidBondId(_bondId);
        BondPosition storage pos = _bonds[_bonder][_bondId];
        return _vested(pos) - pos.claimedSynth;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the SolvencyManager allowed to activate bonding rounds
     * @param _solvencyManager The SolvencyManager address
     */
    function setSolvencyManager(address _solvencyManager) external onlyOwner {
        if (_solvencyManager == address(0)) revert ZeroAddress();
        solvencyManager = _solvencyManager;
        emit SolvencyManagerUpdated(_solvencyManager);
    }

    /**
     * @notice Update the $SYNTH reference price (USDC per SYNTH, 6 decimals), proxy for a TWAP
     * @param _referencePrice New reference price
     */
    function setReferencePrice(uint256 _referencePrice) external onlyOwner {
        if (_referencePrice == 0) revert ZeroAmount();
        referencePrice = _referencePrice;
        emit ReferencePriceUpdated(_referencePrice);
    }

    /**
     * @notice Update the bond discount in BPS (capped at MAX_DISCOUNT_BPS)
     * @param _discountBps New discount in BPS
     */
    function setDiscountBps(uint256 _discountBps) external onlyOwner {
        if (_discountBps > MAX_DISCOUNT_BPS) revert DiscountTooHigh(_discountBps);
        discountBps = _discountBps;
        emit DiscountUpdated(_discountBps);
    }

    /**
     * @notice Update the linear vesting window applied to new bonds (capped at MAX_VESTING_PERIOD)
     * @dev Only affects bonds created after the change; existing positions keep their original window.
     * @param _vestingPeriod New vesting period in seconds (0 == instant)
     */
    function setVestingPeriod(uint256 _vestingPeriod) external onlyOwner {
        if (_vestingPeriod > MAX_VESTING_PERIOD) revert VestingPeriodTooLong(_vestingPeriod);
        vestingPeriod = _vestingPeriod;
        emit VestingPeriodUpdated(_vestingPeriod);
    }
}
