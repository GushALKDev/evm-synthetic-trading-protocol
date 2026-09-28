// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {TradingStorage} from "./TradingStorage.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {OpenPnlLib} from "./libraries/OpenPnlLib.sol";

/// @title Vault
/// @author GushALKDev
/// @notice ERC-4626 Vault with Single-Sided Liquidity for Synthetic Trading Protocol
/// @dev Implements a withdrawal lock mechanism to prevent front-running of trader payouts.
///      Requested shares are escrowed in the vault itself: returned on cancel or on a new request, burned on
///      execution. A request can be executed only during WITHDRAWAL_WINDOW_EPOCHS after it unlocks.
///      totalAssets is a conservative NAV: the USDC balance minus the positive net unrealised trader PnL from the
///      latest snapshot (refreshPnlSnapshot). Net trader losses are not added. deposit, mint and
///      executeWithdrawal need a fresh snapshot: no open trade, or taken within maxPnlSnapshotAge with no position
///      opened or closed since. The refreshAnd* entry points refresh and act in one transaction.
contract Vault is ERC4626, Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant WITHDRAWAL_DELAY_EPOCHS = 3;

    /**
     * @notice Epochs after unlock during which a request can be executed; after that it has expired
     * @dev One epoch gives the LP a full day to execute. It also bounds how much of a position can be kept
     *      in an execute-at-will state by staggering requests across addresses: WINDOW / (DELAY + WINDOW) = 25%.
     */
    uint256 public constant WITHDRAWAL_WINDOW_EPOCHS = 1;

    /**
     * @notice WAD scalar (1e18) used to express the collateralization ratio
     * @dev CR == 1e18 means share price is exactly at its nominal deposit value
     */
    uint256 public constant WAD = 1e18;

    /**
     * @notice Default maximum age of the PnL snapshot for actions that price shares, and its immutable ceiling
     */
    uint256 public constant DEFAULT_MAX_PNL_SNAPSHOT_AGE = 60; // seconds
    uint256 public constant MAX_PNL_SNAPSHOT_AGE_CEILING = 3600; // seconds

    /// @dev Transient slot holding the Vault's ETH balance before the current call's msg.value
    bytes32 private constant _ETH_BASELINE_SLOT = keccak256("Vault.ethBaseline");

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The underlying asset (USDC)
     */
    address public immutable ASSET;

    /**
     * @notice Deployment timestamp used as epoch origin (epoch 0)
     */
    uint256 public immutable DEPLOY_TIMESTAMP;

    /**
     * @notice Source of the open position aggregates valued by the PnL snapshot
     */
    TradingStorage public immutable TRADING_STORAGE;

    /**
     * @notice Oracle used by the PnL snapshot (same checks as trade execution)
     */
    IOracle public immutable ORACLE;

    /**
     * @notice The trading engine address authorized to request payouts
     * @dev Packed with _paused and maxPnlSnapshotAge in one slot (20 + 1 + 4 = 25 bytes)
     */
    address public tradingEngine;

    /**
     * @notice Whether the vault is paused (packed with tradingEngine)
     */
    bool private _paused;

    /**
     * @notice Maximum age of the PnL snapshot for deposit, mint and executeWithdrawal, in seconds
     */
    uint32 public maxPnlSnapshotAge;

    /**
     * @notice Net unrealised trader PnL of all open positions, valued at refresh time
     * @dev netPnl is USDC (6 decimals), positive when traders are in profit, rounded to overstate trader profit.
     *      nonce is TradingStorage's positions nonce at refresh time; any open or close changes it.
     */
    struct PnlSnapshot {
        int128 netPnl; //   16 bytes -┐
        uint48 timestamp; // 6 bytes  │  Slot 0 (26/32)
        uint32 nonce; //     4 bytes -┘
    }

    /**
     * @notice Defines a withdrawal request
     */
    struct WithdrawalRequest {
        uint256 shares;
        uint256 requestEpoch;
    }

    /**
     * @notice User withdrawal requests
     */
    mapping(address => WithdrawalRequest) public withdrawalRequests;

    /**
     * @notice Latest PnL snapshot
     */
    PnlSnapshot public pnlSnapshot;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawalRequested(address indexed owner, uint256 shares, uint256 requestEpoch, uint256 unlockEpoch);
    event WithdrawalExecuted(address indexed owner, uint256 shares, uint256 assets);
    event PayoutSent(address indexed receiver, uint256 amount);
    event TradingEngineUpdated(address indexed newEngine);
    event WithdrawalCancelled(address indexed owner);
    event Paused(address account);
    event Unpaused(address account);
    event PnlSnapshotRefreshed(int256 netPnl, uint256 timestamp);
    event MaxPnlSnapshotAgeUpdated(uint256 maxPnlSnapshotAge);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientVaultBalance(uint256 amount, uint256 balance);
    error InsufficientShares(uint256 shares, uint256 balance);
    error WithdrawalLocked(uint256 unlockEpoch);
    error WithdrawalExpired(uint256 expiryEpoch);
    error CallerNotTradingEngine();
    error UseRequestWithdrawalFlow();
    error NoWithdrawalRequest();
    error EnforcedPause();
    error ExpectedPause();
    error ZeroAddress();
    error StalePnlSnapshot(uint256 snapshotTimestamp);
    error InvalidMaxPnlSnapshotAge(uint256 maxPnlSnapshotAge);
    error CoverageBelowPar(uint256 ratio);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    modifier whenPaused() {
        _requirePaused();
        _;
    }

    /**
     * @dev Refund, at the end of the call, only the ETH this call added (msg.value minus the oracle fee paid)
     */
    modifier refundsEthSurplus() {
        _recordEthBaseline();
        _;
        _refundEth();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireNotPaused() internal view {
        if (_paused) revert EnforcedPause();
    }

    function _requirePaused() internal view {
        if (!_paused) revert ExpectedPause();
    }

    function _requireFreshPnlSnapshot() internal view {
        if (!isPnlSnapshotFresh()) revert StalePnlSnapshot(pnlSnapshot.timestamp);
    }

    /**
     * @dev Below 100% a new deposit would buy shares under 1.0 and take part of the next injection or bond
     *      proceeds meant for the LPs who carried the loss
     */
    function _requireCoverageAtPar() internal view {
        uint256 ratio = collateralizationRatio();
        if (ratio < WAD) revert CoverageBelowPar(ratio);
    }

    function _recordEthBaseline() internal {
        uint256 baseline = address(this).balance - msg.value;
        bytes32 slot = _ETH_BASELINE_SLOT;
        assembly {
            tstore(slot, baseline)
        }
    }

    function _refundEth() internal {
        uint256 baseline;
        bytes32 slot = _ETH_BASELINE_SLOT;
        assembly {
            baseline := tload(slot)
        }
        uint256 surplus = address(this).balance - baseline;
        if (surplus > 0) msg.sender.safeTransferETH(surplus);
    }

    /**
     * @dev Positive part of the snapshot's net trader PnL; zero when no trade is open
     */
    function _openPnlLiability() internal view returns (uint256) {
        (uint32 openTrades,) = TRADING_STORAGE.getPositionState();
        if (openTrades == 0) return 0;
        int256 netPnl = pnlSnapshot.netPnl;
        return netPnl > 0 ? uint256(netPnl) : 0;
    }

    /**
     * @dev Value the open positions of every pair with open interest and store the snapshot.
     *      The update data and msg.value go to the first priced pair; later pairs read the prices it stored, so
     *      the caller must bring updates for every pair with open interest (or their stored prices must be
     *      within the oracle's age limit). Each price goes through the oracle's checks.
     */
    function _refreshPnlSnapshot(bytes[] calldata _priceUpdate) internal {
        uint256 pairsCount = TRADING_STORAGE.getPairsCount();
        bytes[] memory noUpdate;
        bool pythUpdated;
        int256 netWad;
        for (uint256 i; i < pairsCount; ++i) {
            OpenPnlLib.PairTotals memory totals = TRADING_STORAGE.getPairOpenTotals(i);
            if (totals.longSize == 0 && totals.shortSize == 0) continue;
            uint128 price;
            uint128 conf;
            if (pythUpdated) {
                (price, conf) = ORACLE.getPrice(i, noUpdate);
            } else {
                (price, conf) = ORACLE.getPrice{value: msg.value}(i, _priceUpdate);
                pythUpdated = true;
            }
            netWad += OpenPnlLib.pairPnl(price, conf, totals);
        }
        (, uint32 nonce) = TRADING_STORAGE.getPositionState();
        int256 netPnl = OpenPnlLib.toUsdcUp(netWad);
        pnlSnapshot = PnlSnapshot({netPnl: SafeCastLib.toInt128(netPnl), timestamp: uint48(block.timestamp), nonce: nonce});
        emit PnlSnapshotRefreshed(netPnl, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _asset USDC
     * @param _owner Contract owner
     * @param _tradingStorage TradingStorage holding the open position aggregates
     * @param _oracle Oracle used to value the open positions
     */
    constructor(address _asset, address _owner, address _tradingStorage, address _oracle) {
        if (_asset == address(0) || _tradingStorage == address(0) || _oracle == address(0)) revert ZeroAddress();
        _initializeOwner(_owner);
        ASSET = _asset;
        DEPLOY_TIMESTAMP = block.timestamp;
        TRADING_STORAGE = TradingStorage(_tradingStorage);
        ORACLE = IOracle(_oracle);
        maxPnlSnapshotAge = uint32(DEFAULT_MAX_PNL_SNAPSHOT_AGE);
    }

    /**
     * @dev Accept the oracle's fee refunds; refundsEthSurplus returns them to the caller
     */
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                           ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function asset() public view virtual override returns (address) {
        return ASSET;
    }

    function name() public view virtual override returns (string memory) {
        return "Synthetic Liquidity Token";
    }

    function symbol() public view virtual override returns (string memory) {
        return "sUSDC";
    }

    /**
     * @dev Override to force 18 decimals even if asset has 6
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev Offset to handle USDC (6 decimals) -> sToken (18 decimals) conversion
     * This makes 1 USDC deposit mint 1e12 more raw shares units, so 1.0 USDC = 1.0 sToken
     * Example: deposit 1e6 USDC → 1e18 shares (1.0 sToken displayed to user)
     */
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 12;
    }

    /**
     * @notice Conservative NAV: USDC balance minus the positive net unrealised trader PnL of the latest snapshot
     * @dev Uses the latest snapshot even if stale, so it never reverts; previews and convertTo* use it too.
     *      Net trader losses are not added.
     */
    function totalAssets() public view virtual override returns (uint256) {
        uint256 balance = SafeTransferLib.balanceOf(ASSET, address(this));
        uint256 liability = _openPnlLiability();
        return balance > liability ? balance - liability : 0;
    }

    /**
     * @dev Needs a fresh PnL snapshot (see isPnlSnapshotFresh) and a coverage ratio of at least 100%
     */
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant whenNotPaused returns (uint256 shares) {
        _requireFreshPnlSnapshot();
        _requireCoverageAtPar();
        return super.deposit(assets, receiver);
    }

    /**
     * @dev Needs a fresh PnL snapshot (see isPnlSnapshotFresh) and a coverage ratio of at least 100%
     */
    function mint(uint256 shares, address receiver) public virtual override nonReentrant whenNotPaused returns (uint256 assets) {
        _requireFreshPnlSnapshot();
        _requireCoverageAtPar();
        return super.mint(shares, receiver);
    }

    /**
     * @notice Refresh the PnL snapshot, then deposit
     */
    function refreshAndDeposit(uint256 assets, address receiver, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        whenNotPaused
        refundsEthSurplus
        returns (uint256 shares)
    {
        _refreshPnlSnapshot(priceUpdate);
        _requireCoverageAtPar();
        shares = super.deposit(assets, receiver);
    }

    /**
     * @notice Refresh the PnL snapshot, then mint
     */
    function refreshAndMint(uint256 shares, address receiver, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        whenNotPaused
        refundsEthSurplus
        returns (uint256 assets)
    {
        _refreshPnlSnapshot(priceUpdate);
        _requireCoverageAtPar();
        assets = super.mint(shares, receiver);
    }

    /**
     * @dev Block standard redeem/withdraw to enforce the request/execute flow
     */
    function redeem(uint256, address, address) public virtual override returns (uint256) {
        revert UseRequestWithdrawalFlow();
    }

    function withdraw(uint256, address, address) public virtual override returns (uint256) {
        revert UseRequestWithdrawalFlow();
    }

    /**
     * @dev ERC-4626 requires max* to report what the action accepts: deposit and mint revert while paused, with a
     *      stale PnL snapshot, or with a coverage ratio below 100%
     */
    function maxDeposit(address to) public view virtual override returns (uint256) {
        return _depositsOpen() ? super.maxDeposit(to) : 0;
    }

    function maxMint(address to) public view virtual override returns (uint256) {
        return _depositsOpen() ? super.maxMint(to) : 0;
    }

    function _depositsOpen() internal view returns (bool) {
        return !_paused && isPnlSnapshotFresh() && collateralizationRatio() >= WAD;
    }

    /**
     * @dev withdraw and redeem always revert (request/execute flow), so nothing can be withdrawn through them
     */
    function maxWithdraw(address) public view virtual override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public view virtual override returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL MECHANISM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Request a withdrawal of shares; the shares are moved into escrow in the vault
     * @dev Replaces any existing request: its escrowed shares are returned first, then the new amount is escrowed.
     * @param shares The amount of shares to withdraw
     */
    function requestWithdrawal(uint256 shares) external nonReentrant whenNotPaused {
        uint256 escrowed = withdrawalRequests[msg.sender].shares;
        uint256 balance = balanceOf(msg.sender) + escrowed;
        if (balance < shares) revert InsufficientShares(shares, balance);

        uint256 epoch = currentEpoch();
        uint256 unlockEpoch = epoch + WITHDRAWAL_DELAY_EPOCHS;

        withdrawalRequests[msg.sender] = WithdrawalRequest({shares: shares, requestEpoch: epoch});
        if (escrowed != 0) _transfer(address(this), msg.sender, escrowed);
        _transfer(msg.sender, address(this), shares);

        emit WithdrawalRequested(msg.sender, shares, epoch, unlockEpoch);
    }

    /**
     * @notice Cancel a withdrawal request (pending, unlocked or expired) and get the escrowed shares back
     */
    function cancelWithdrawal() external {
        uint256 shares = withdrawalRequests[msg.sender].shares;
        if (shares == 0) revert NoWithdrawalRequest();

        delete withdrawalRequests[msg.sender];
        _transfer(address(this), msg.sender, shares);

        emit WithdrawalCancelled(msg.sender);
    }

    /**
     * @notice Execute a withdrawal request between its unlock epoch and the end of its window
     * @dev An expired request cannot be executed; cancelWithdrawal or a new request returns its shares.
     *      Pays at the conservative NAV, so it needs a fresh PnL snapshot.
     */
    function executeWithdrawal() external nonReentrant {
        _requireFreshPnlSnapshot();
        _executeWithdrawal();
    }

    /**
     * @notice Refresh the PnL snapshot, then execute the caller's withdrawal request
     */
    function refreshAndExecuteWithdrawal(bytes[] calldata priceUpdate) external payable nonReentrant refundsEthSurplus {
        _refreshPnlSnapshot(priceUpdate);
        _executeWithdrawal();
    }

    function _executeWithdrawal() internal {
        WithdrawalRequest storage req = withdrawalRequests[msg.sender];
        if (req.shares == 0) revert NoWithdrawalRequest();

        uint256 unlockEpoch = req.requestEpoch + WITHDRAWAL_DELAY_EPOCHS;
        uint256 epoch = currentEpoch();
        if (epoch < unlockEpoch) revert WithdrawalLocked(unlockEpoch);
        if (epoch >= unlockEpoch + WITHDRAWAL_WINDOW_EPOCHS) revert WithdrawalExpired(unlockEpoch + WITHDRAWAL_WINDOW_EPOCHS);

        uint256 sharesToBurn = req.shares;
        // Assets calculated at execution time (price per share may have changed since request)
        uint256 assets = previewRedeem(sharesToBurn);

        // Clear request before external calls (CEI)
        delete withdrawalRequests[msg.sender];

        // Burn the escrowed shares
        _burn(address(this), sharesToBurn);
        emit WithdrawalExecuted(msg.sender, sharesToBurn, assets);

        // Transfer assets
        ASSET.safeTransfer(msg.sender, assets);
    }

    function currentEpoch() public view returns (uint256) {
        // Epoch 0 = deployment day, epoch 1 = next day, etc.
        return (block.timestamp - DEPLOY_TIMESTAMP) / EPOCH_LENGTH;
    }

    /**
     * @notice Get the epoch when a user's withdrawal will unlock
     * @param user The user address to check
     * @return unlockEpoch The epoch when withdrawal can be executed (0 if no request)
     */
    function getWithdrawalUnlockEpoch(address user) external view returns (uint256 unlockEpoch) {
        WithdrawalRequest storage req = withdrawalRequests[user];
        if (req.shares == 0) return 0;
        return req.requestEpoch + WITHDRAWAL_DELAY_EPOCHS;
    }

    /**
     * @notice Check if a user can execute their withdrawal (unlocked and not expired)
     * @param user The user address to check
     * @return True if withdrawal can be executed
     */
    function canExecuteWithdrawal(address user) external view returns (bool) {
        WithdrawalRequest storage req = withdrawalRequests[user];
        if (req.shares == 0) return false;
        uint256 unlockEpoch = req.requestEpoch + WITHDRAWAL_DELAY_EPOCHS;
        uint256 epoch = currentEpoch();
        return epoch >= unlockEpoch && epoch < unlockEpoch + WITHDRAWAL_WINDOW_EPOCHS;
    }

    /**
     * @notice Get the time remaining until a user's withdrawal unlocks
     * @param user The user address to check
     * @return Time in seconds until withdrawal unlocks (0 if already unlocked or no request)
     */
    function timeUntilWithdrawal(address user) external view returns (uint256) {
        WithdrawalRequest storage req = withdrawalRequests[user];
        if (req.shares == 0) return 0;

        uint256 unlockTimestamp = DEPLOY_TIMESTAMP + (req.requestEpoch + WITHDRAWAL_DELAY_EPOCHS) * EPOCH_LENGTH;
        if (block.timestamp >= unlockTimestamp) return 0;
        return unlockTimestamp - block.timestamp;
    }

    /**
     * @notice LP principal coverage ratio: share price at the conservative NAV relative to 1.0 (WAD, 1e18 == 100%)
     * @dev CR compares the conservative NAV (totalAssets) against the nominal deposit basis of all outstanding
     *      shares. At the nominal 1:1 mint price, totalSupply shares are worth `totalSupply / 10**offset`
     *      USDC, so CR = totalAssets * 10**offset * WAD / totalSupply. CR < 1e18 means the NAV is below what LPs
     *      paid in at 1.0 per share. It does not measure whether the Vault can pay every open trade at its cap,
     *      and it uses the latest PnL snapshot even if stale. When totalSupply == 0 it reports max.
     * @return ratio The collateralization ratio in WAD
     */
    function collateralizationRatio() public view returns (uint256 ratio) {
        uint256 supply = totalSupply();
        if (supply == 0) return type(uint256).max;
        return (totalAssets() * (10 ** _decimalsOffset()) * WAD) / supply;
    }

    /**
     * @notice Realised collateralization ratio: the USDC balance per share relative to 1.0, ignoring open PnL (WAD)
     * @dev Used for bonding, so $SYNTH is not sold at a discount because of an unrealised move that can reverse.
     */
    function realisedCollateralizationRatio() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return type(uint256).max;
        return (SafeTransferLib.balanceOf(ASSET, address(this)) * (10 ** _decimalsOffset()) * WAD) / supply;
    }

    /**
     * @notice USDC needed to bring the realised collateralization ratio back to 100%
     */
    function realisedCollateralizationDeficit() external view returns (uint256) {
        uint256 nominalLiabilities = totalSupply() / (10 ** _decimalsOffset());
        uint256 balance = SafeTransferLib.balanceOf(ASSET, address(this));
        return nominalLiabilities > balance ? nominalLiabilities - balance : 0;
    }

    /**
     * @notice Whether the PnL snapshot can price shares: no open trade, or taken within maxPnlSnapshotAge with no
     *         position opened or closed since
     */
    function isPnlSnapshotFresh() public view returns (bool) {
        (uint32 openTrades, uint32 nonce) = TRADING_STORAGE.getPositionState();
        if (openTrades == 0) return true;
        PnlSnapshot memory snapshot = pnlSnapshot;
        return snapshot.timestamp != 0 && snapshot.nonce == nonce && block.timestamp - snapshot.timestamp <= maxPnlSnapshotAge;
    }

    /**
     * @notice Refresh the PnL snapshot: value the open positions of every pair with open interest
     * @dev Permissionless. msg.value funds the oracle fee; only msg.value minus the fee paid is refunded.
     * @param priceUpdate Pyth update data for every pair with open interest
     */
    function refreshPnlSnapshot(bytes[] calldata priceUpdate) external payable nonReentrant refundsEthSurplus {
        _refreshPnlSnapshot(priceUpdate);
    }

    /**
     * @notice USDC needed to bring the conservative NAV back to a 100% collateralization ratio
     * @dev Derived from the nominal deposit basis of outstanding shares rather than from the ratio,
     *      so it stays well-defined when the Vault is fully drained (totalAssets == 0 with shares
     *      outstanding), which is precisely when a rescue must remain callable.
     * @return deficit USDC amount (6 decimals) required to reach 100%, or 0 if already at/above
     */
    function collateralizationDeficit() external view returns (uint256 deficit) {
        uint256 nominalLiabilities = totalSupply() / (10 ** _decimalsOffset());
        uint256 assets = totalAssets();
        return nominalLiabilities > assets ? nominalLiabilities - assets : 0;
    }

    /*//////////////////////////////////////////////////////////////
                            PROTOCOL ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Send payout to a trader (called by Trading Engine)
     * @param receiver The trader receiving the profit
     * @param amount The amount of USDC to send
     */
    function sendPayout(address receiver, uint256 amount) external nonReentrant {
        // Compared with the USDC balance: totalAssets already subtracts the unrealised profit being paid here
        uint256 balance = SafeTransferLib.balanceOf(ASSET, address(this));
        if (msg.sender != tradingEngine) revert CallerNotTradingEngine();
        if (amount > balance) revert InsufficientVaultBalance(amount, balance);

        // Transfers LP liquidity to winning traders (does not affect share price calculation)
        emit PayoutSent(receiver, amount);
        ASSET.safeTransfer(receiver, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the maximum age of the PnL snapshot for deposit, mint and executeWithdrawal
     * @param _maxPnlSnapshotAge Seconds, from 1 to MAX_PNL_SNAPSHOT_AGE_CEILING
     */
    function setMaxPnlSnapshotAge(uint256 _maxPnlSnapshotAge) external onlyOwner {
        if (_maxPnlSnapshotAge == 0 || _maxPnlSnapshotAge > MAX_PNL_SNAPSHOT_AGE_CEILING) revert InvalidMaxPnlSnapshotAge(_maxPnlSnapshotAge);
        maxPnlSnapshotAge = uint32(_maxPnlSnapshotAge);
        emit MaxPnlSnapshotAgeUpdated(_maxPnlSnapshotAge);
    }

    function setTradingEngine(address _tradingEngine) external onlyOwner {
        if (_tradingEngine == address(0)) revert ZeroAddress();
        tradingEngine = _tradingEngine;
        emit TradingEngineUpdated(_tradingEngine);
    }

    function pause() external onlyOwner whenNotPaused {
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner whenPaused {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    function paused() external view returns (bool) {
        return _paused;
    }
}
