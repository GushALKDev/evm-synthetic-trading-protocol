// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {BondDepository} from "../../../src/BondDepository.sol";
import {SynthToken} from "../../../src/SynthToken.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title BondingHandler
 * @author GushALKDev
 * @notice Stateful fuzzing handler for the bonding / vesting flow (BondDepository + SynthToken).
 * @dev Drives rounds, purchases, claims and admin re-pricing. Ghost variables track the total $SYNTH
 *      promised to bonders and the total actually claimed, so the invariants can assert the
 *      depository always holds enough tokens to honour every outstanding vesting position.
 */
contract BondingHandler is CommonBase, StdCheats, StdUtils {
    BondDepository public immutable BOND;
    SynthToken public immutable SYNTH;
    ERC20 public immutable USDC;
    address public immutable SOLVENCY_MANAGER;
    address public immutable OWNER;

    address[] public bonders;
    address internal currentBonder;

    /// @notice Total $SYNTH promised across every bond position ever created
    uint256 public ghostTotalPromised;
    /// @notice Total $SYNTH actually claimed by bonders
    uint256 public ghostTotalClaimed;
    /// @notice Total USDC raised through bonding
    uint256 public ghostUsdcRaised;

    mapping(bytes32 => uint256) public calls;

    modifier countCall(bytes32 _key) {
        calls[_key]++;
        _;
    }

    constructor(BondDepository _bond, SynthToken _synth, ERC20 _usdc, address _solvencyManager, address _owner) {
        BOND = _bond;
        SYNTH = _synth;
        USDC = _usdc;
        SOLVENCY_MANAGER = _solvencyManager;
        OWNER = _owner;

        for (uint256 i; i < 3; ++i) {
            bonders.push(address(uint160(uint256(keccak256(abi.encode("bonder", i))))));
        }
    }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice SolvencyManager opens a round (no-op if one is already active)
    function activateBonding(uint256 _needed) external countCall("activateBonding") {
        if (BOND.isActive()) return;
        uint256 needed = bound(_needed, 1 * 10 ** 6, 500_000 * 10 ** 6);
        vm.startPrank(SOLVENCY_MANAGER);
        BOND.activateBonding(needed);
        vm.stopPrank();
    }

    /// @notice A bonder buys discounted $SYNTH (no-op when no round is open)
    function bond(uint256 _bonderSeed, uint256 _usdcAmount) external countCall("bond") {
        if (!BOND.isActive()) return;
        currentBonder = bonders[bound(_bonderSeed, 0, bonders.length - 1)];

        uint256 amount = bound(_usdcAmount, 1 * 10 ** 6, 100_000 * 10 ** 6);
        deal(address(USDC), currentBonder, amount);

        // bond() clamps the deposit to the remaining cap, so measure what the Vault actually received
        uint256 vaultBefore = USDC.balanceOf(BOND.VAULT());

        vm.startPrank(currentBonder);
        USDC.approve(address(BOND), amount);
        (, uint256 synthOut) = BOND.bond(amount);
        vm.stopPrank();

        ghostTotalPromised += synthOut;
        ghostUsdcRaised += USDC.balanceOf(BOND.VAULT()) - vaultBefore;
    }

    /// @notice A bonder claims whatever has vested so far (no-op when nothing is claimable)
    function claim(uint256 _bonderSeed, uint256 _bondSeed) external countCall("claim") {
        address bonder = bonders[bound(_bonderSeed, 0, bonders.length - 1)];
        uint256 count = BOND.bondCount(bonder);
        if (count == 0) return;

        uint256 bondId = bound(_bondSeed, 0, count - 1);
        if (BOND.claimable(bonder, bondId) == 0) return;

        vm.startPrank(bonder);
        uint256 claimed = BOND.claim(bondId);
        vm.stopPrank();

        ghostTotalClaimed += claimed;
    }

    /// @notice Advance time so vesting progresses
    function warp(uint256 _timeSeed) external countCall("warp") {
        vm.warp(block.timestamp + bound(_timeSeed, 1 minutes, 10 days));
    }

    /// @notice Owner re-prices bonds within the contract's allowed bounds
    function setReferencePrice(uint256 _priceSeed) external countCall("setReferencePrice") {
        uint256 price = bound(_priceSeed, 1 * 10 ** 5, 100 * 10 ** 6);
        vm.startPrank(OWNER);
        BOND.setReferencePrice(price);
        vm.stopPrank();
    }

    /// @notice Owner adjusts the discount within the MAX_DISCOUNT_BPS cap
    function setDiscountBps(uint256 _discountSeed) external countCall("setDiscountBps") {
        uint256 discount = bound(_discountSeed, 0, BOND.MAX_DISCOUNT_BPS());
        vm.startPrank(OWNER);
        BOND.setDiscountBps(discount);
        vm.stopPrank();
    }

    /// @notice Owner adjusts the vesting window within the MAX_VESTING_PERIOD cap
    function setVestingPeriod(uint256 _periodSeed) external countCall("setVestingPeriod") {
        uint256 period = bound(_periodSeed, 0, BOND.MAX_VESTING_PERIOD());
        vm.startPrank(OWNER);
        BOND.setVestingPeriod(period);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function bondersLength() external view returns (uint256) {
        return bonders.length;
    }
}
