// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Vault
/// @author GushALKDev
/// @notice ERC-4626 Vault with Single-Sided Liquidity for Synthetic Trading Protocol
/// @dev Implements a withdrawal lock mechanism to prevent front-running of trader payouts
contract Vault is ERC4626, Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant WITHDRAWAL_DELAY_EPOCHS = 3;

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
     * @notice The trading engine address authorized to request payouts
     * @dev Packed with _paused in the same slot (address = 20 bytes + bool = 1 byte = 21 bytes < 32)
     */
    address public tradingEngine;

    /**
     * @notice Whether the vault is paused (packed with tradingEngine)
     */
    bool private _paused;

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

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientVaultBalance(uint256 amount, uint256 totalAssets);
    error InsufficientShares(uint256 shares, uint256 balance);
    error WithdrawalLocked(uint256 unlockEpoch);
    error CallerNotTradingEngine();
    error UseRequestWithdrawalFlow();
    error NoWithdrawalRequest();
    error EnforcedPause();
    error ExpectedPause();
    error ZeroAddress();

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

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireNotPaused() internal view {
        if (_paused) revert EnforcedPause();
    }

    function _requirePaused() internal view {
        if (!_paused) revert ExpectedPause();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _asset, address _owner) {
        _initializeOwner(_owner);
        ASSET = _asset;
        DEPLOY_TIMESTAMP = block.timestamp;
    }

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
     * @dev Override deposit to enforce any logic if needed, currently standard
     */
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant whenNotPaused returns (uint256 shares) {
        return super.deposit(assets, receiver);
    }

    /**
     * @dev Override mint to enforce any logic if needed, currently standard
     */
    function mint(uint256 shares, address receiver) public virtual override nonReentrant whenNotPaused returns (uint256 assets) {
        return super.mint(shares, receiver);
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

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL MECHANISM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Request a withdrawal of shares
     * @param shares The amount of shares to withdraw
     */
    function requestWithdrawal(uint256 shares) external nonReentrant whenNotPaused {
        uint256 balance = balanceOf(msg.sender);
        if (balance < shares) revert InsufficientShares(shares, balance);

        uint256 epoch = currentEpoch();
        uint256 unlockEpoch = epoch + WITHDRAWAL_DELAY_EPOCHS;

        // Overwrites any existing request (no need to cancel first)
        withdrawalRequests[msg.sender] = WithdrawalRequest({shares: shares, requestEpoch: epoch});

        emit WithdrawalRequested(msg.sender, shares, epoch, unlockEpoch);
    }

    /**
     * @notice Cancel a pending withdrawal request
     */
    function cancelWithdrawal() external {
        if (withdrawalRequests[msg.sender].shares == 0) revert NoWithdrawalRequest();

        delete withdrawalRequests[msg.sender];

        emit WithdrawalCancelled(msg.sender);
    }

    /**
     * @notice Execute a pending withdrawal request
     */
    function executeWithdrawal() external nonReentrant {
        WithdrawalRequest storage req = withdrawalRequests[msg.sender];
        if (req.shares == 0) revert NoWithdrawalRequest();

        uint256 unlockEpoch = req.requestEpoch + WITHDRAWAL_DELAY_EPOCHS;
        if (currentEpoch() < unlockEpoch) revert WithdrawalLocked(unlockEpoch);

        uint256 sharesToBurn = req.shares;
        // Assets calculated at execution time (price per share may have changed since request)
        uint256 assets = previewRedeem(sharesToBurn);

        // Clear request before external calls (CEI)
        delete withdrawalRequests[msg.sender];

        // Burn shares
        _burn(msg.sender, sharesToBurn);
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
     * @notice Check if a user can execute their withdrawal
     * @param user The user address to check
     * @return True if withdrawal can be executed
     */
    function canExecuteWithdrawal(address user) external view returns (bool) {
        WithdrawalRequest storage req = withdrawalRequests[user];
        if (req.shares == 0) return false;
        return currentEpoch() >= req.requestEpoch + WITHDRAWAL_DELAY_EPOCHS;
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

    /*//////////////////////////////////////////////////////////////
                            PROTOCOL ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Send payout to a trader (called by Trading Engine)
     * @param receiver The trader receiving the profit
     * @param amount The amount of USDC to send
     */
    function sendPayout(address receiver, uint256 amount) external nonReentrant {
        uint256 totalAssets = totalAssets();
        if (msg.sender != tradingEngine) revert CallerNotTradingEngine();
        if (amount > totalAssets) revert InsufficientVaultBalance(amount, totalAssets);

        // Transfers LP liquidity to winning traders (does not affect share price calculation)
        emit PayoutSent(receiver, amount);
        ASSET.safeTransfer(receiver, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
