// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title LiquidityVault
/// @author GushALKDev
/// @notice ERC-4626 Vault with Single-Sided Liquidity for Synthetic Trading Protocol
/// @dev Implements a withdrawal lock mechanism to prevent front-running of trader payouts
contract LiquidityVault is ERC4626, Ownable, ReentrancyGuard {
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
     * @notice The trading protocol address authorized to request payouts
     * @dev Packed with _paused in the same slot (address = 20 bytes + bool = 1 byte = 21 bytes < 32)
     */
    address public tradingProtocol;

    /**
     * @notice Whether the vault is paused (packed with tradingProtocol)
     */
    bool private _paused;

    /**
     * @notice The solvency manager address authorized to inject funds
     */
    address public solvencyManager;

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
    event FundsInjected(uint256 amount);
    event TradingProtocolUpdated(address indexed newProtocol);
    event SolvencyManagerUpdated(address indexed newManager);
    event WithdrawalCancelled(address indexed owner);
    event Paused(address account);
    event Unpaused(address account);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error WithdrawalLocked(uint256 unlockEpoch);
    error NoWithdrawalRequest();
    error InsufficientVaultBalance();
    error CallerNotTradingProtocol();
    error InsufficientShares();
    error UseRequestWithdrawalFlow();
    error ZeroAddress();
    error EnforcedPause();
    error ExpectedPause();

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
     */
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 12;
    }

    /**
     * @dev Override deposit to enforce any logic if needed, currently standard
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public virtual override nonReentrant whenNotPaused returns (uint256 shares) {
        return super.deposit(assets, receiver);
    }

    /**
     * @dev Override mint to enforce any logic if needed, currently standard
     */
    function mint(
        uint256 shares,
        address receiver
    ) public virtual override nonReentrant whenNotPaused returns (uint256 assets) {
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
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint256 epoch = currentEpoch();
        uint256 unlockEpoch = epoch + WITHDRAWAL_DELAY_EPOCHS;

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
        uint256 assets = previewRedeem(sharesToBurn);

        // Clear request before external calls (CEI)
        delete withdrawalRequests[msg.sender];

        // Burn shares
        _burn(msg.sender, sharesToBurn);

        // Transfer assets
        ASSET.safeTransfer(msg.sender, assets);

        emit WithdrawalExecuted(msg.sender, sharesToBurn, assets);
    }

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
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

        uint256 unlockTimestamp = (req.requestEpoch + WITHDRAWAL_DELAY_EPOCHS) * EPOCH_LENGTH;
        if (block.timestamp >= unlockTimestamp) return 0;
        return unlockTimestamp - block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                            PROTOCOL ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Send payout to a trader (called by Trading Protocol)
     * @param receiver The trader receiving the profit
     * @param amount The amount of USDC to send
     */
    function sendPayout(address receiver, uint256 amount) external nonReentrant {
        if (msg.sender != tradingProtocol) revert CallerNotTradingProtocol();
        if (amount > totalAssets()) revert InsufficientVaultBalance();

        ASSET.safeTransfer(receiver, amount);
        emit PayoutSent(receiver, amount);
    }

    /**
     * @notice Receive fee injection or solvency rescue (called by Solvency Manager or anyone willing to donate)
     * @dev Just a transfer, but we can have a hook if needed.
     * Since we use balanceOf(this) for accounting, simple transfers work.
     */
    function injectFunds(uint256 amount) external {
        ASSET.safeTransferFrom(msg.sender, address(this), amount);
        emit FundsInjected(amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setTradingProtocol(address _tradingProtocol) external onlyOwner {
        if (_tradingProtocol == address(0)) revert ZeroAddress();
        tradingProtocol = _tradingProtocol;
        emit TradingProtocolUpdated(_tradingProtocol);
    }

    function setSolvencyManager(address _solvencyManager) external onlyOwner {
        if (_solvencyManager == address(0)) revert ZeroAddress();
        solvencyManager = _solvencyManager;
        emit SolvencyManagerUpdated(_solvencyManager);
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
