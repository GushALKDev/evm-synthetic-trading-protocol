// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {RegressionUSDC} from "../regression/RegressionBase.sol";

/**
 * @title VaultErc4626Test
 * @author GushALKDev
 * @notice ERC-4626 conformity of the Vault with the conservative NAV: previews against actions with a fresh
 *         snapshot, rounding direction per EIP-4626 (in favour of the Vault), convertTo* and totalAssets that do
 *         not revert, and the sUSDC ERC-20 behaviour the escrow adds on top of Solady.
 * @dev Positions are written straight into TradingStorage from a pranked engine address, as in VaultNav.t.sol, so
 *      a test controls the open PnL liability exactly. No SolvencyManager is set: the deposit gate is covered by
 *      VaultDepositRule.t.sol.
 */
contract VaultErc4626Test is Test {
    Vault vault;
    TradingStorage tradingStorage;
    MockOracle mockOracle;
    RegressionUSDC usdc;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address other = makeAddr("other");
    address engine = makeAddr("engine");

    uint16 constant PAIR = 0;
    uint128 constant PRICE = 50_000 * 1e18;
    uint256 constant LP_DEPOSIT = 1_000_000 * 10 ** 6;
    bytes[] EMPTY;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        mockOracle = new MockOracle();
        mockOracle.setPrice(PAIR, PRICE);

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner, address(tradingStorage), address(mockOracle));
        tradingStorage.setTradingEngine(engine);
        vault.setTradingEngine(engine);
        tradingStorage.addPair("BTC/USD", 100, type(uint128).max);
        vm.stopPrank();

        usdc.mint(lp, 100 * LP_DEPOSIT);
        vm.prank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(lp);
        vault.deposit(LP_DEPOSIT, lp);
    }

    /**
     * @dev A non-trivial share price: fee income or losses on the balance, then a long whose profit becomes the
     *      snapshot liability after a price move
     */
    function _setNav(uint256 _donation, uint256 _payout, uint256 _priceBps) internal {
        usdc.mint(address(vault), bound(_donation, 0, LP_DEPOSIT / 10));
        vm.prank(engine);
        vault.sendPayout(makeAddr("winner"), bound(_payout, 0, LP_DEPOSIT / 2));
        vm.startPrank(engine);
        tradingStorage.storeTrade(other, true, PAIR, 10, 1_000 * 10 ** 6, PRICE, 0, 0);
        tradingStorage.increaseOpenInterest(PAIR, 1_000 * 10 ** 6 * 10 * 1e12, true);
        vm.stopPrank();
        mockOracle.setPrice(PAIR, uint128((uint256(PRICE) * bound(_priceBps, 9_000, 11_000)) / 10_000));
        vault.refreshPnlSnapshot(EMPTY);
    }

    /*//////////////////////////////////////////////////////////////
                       PREVIEWS AGAINST ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice previewDeposit and previewMint equal what deposit and mint do with a fresh snapshot
    function testFuzz_PreviewsEqualActions(uint256 _donation, uint256 _payout, uint256 _priceBps, uint256 _assets, uint256 _shares) public {
        _setNav(_donation, _payout, _priceBps);
        uint256 assets = bound(_assets, 1, LP_DEPOSIT);
        uint256 preview = vault.previewDeposit(assets);
        vm.prank(lp);
        assertEq(vault.deposit(assets, lp), preview, "deposit != previewDeposit");

        uint256 shares = bound(_shares, 1, LP_DEPOSIT * 1e12);
        uint256 previewAssets = vault.previewMint(shares);
        vm.prank(lp);
        assertEq(vault.mint(shares, lp), previewAssets, "mint != previewMint");
    }

    /**
     * @notice Rounding favours the Vault: convertToShares, convertToAssets, previewDeposit and previewRedeem round
     *         down; previewMint and previewWithdraw round up
     */
    function testFuzz_RoundingDirection(uint256 _donation, uint256 _payout, uint256 _priceBps, uint256 _amount) public {
        _setNav(_donation, _payout, _priceBps);
        uint256 amount = bound(_amount, 1, LP_DEPOSIT * 1e12);
        uint256 supplyPlus = vault.totalSupply() + 1e12;
        uint256 assetsPlus = vault.totalAssets() + 1;

        // Exact rational values against the virtual share and asset offsets
        assertEq(vault.convertToShares(amount), (amount * supplyPlus) / assetsPlus, "convertToShares not floor");
        assertEq(vault.convertToAssets(amount), (amount * assetsPlus) / supplyPlus, "convertToAssets not floor");
        assertEq(vault.previewDeposit(amount), vault.convertToShares(amount), "previewDeposit not floor");
        assertEq(vault.previewRedeem(amount), vault.convertToAssets(amount), "previewRedeem not floor");
        assertEq(vault.previewMint(amount), (amount * assetsPlus + supplyPlus - 1) / supplyPlus, "previewMint not ceil");
        assertEq(vault.previewWithdraw(amount), (amount * supplyPlus + assetsPlus - 1) / assetsPlus, "previewWithdraw not ceil");
    }

    /// @notice executeWithdrawal pays previewRedeem of the escrowed shares, at the NAV of the execution
    function testFuzz_ExecuteWithdrawalPaysPreviewRedeem(uint256 _donation, uint256 _payout, uint256 _priceBps, uint256 _bps) public {
        uint256 shares = (vault.balanceOf(lp) * bound(_bps, 1, 10_000)) / 10_000;
        vm.prank(lp);
        vault.requestWithdrawal(shares);
        vm.warp(block.timestamp + 3 * vault.EPOCH_LENGTH());
        _setNav(_donation, _payout, _priceBps);

        uint256 expected = vault.previewRedeem(shares);
        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        vault.executeWithdrawal();
        assertEq(usdc.balanceOf(lp) - before, expected);
    }

    /*//////////////////////////////////////////////////////////////
                     VIEWS THAT DO NOT REVERT
    //////////////////////////////////////////////////////////////*/

    /// @notice totalAssets, convertTo* and the previews return with a stale snapshot, a liability above the balance and no shares
    function test_ViewsDoNotRevertInEdgeStates() public {
        _setNav(0, LP_DEPOSIT / 2, 11_000);
        vm.warp(block.timestamp + vault.maxPnlSnapshotAge() + 1);
        assertFalse(vault.isPnlSnapshotFresh());
        _callViews(type(uint128).max);

        // Liability above the balance: +200% on 10,000 USD of long notional owes 20,000 USD against 10,000 USDC held
        uint256 drain = usdc.balanceOf(address(vault)) - 10_000 * 10 ** 6;
        vm.prank(engine);
        vault.sendPayout(makeAddr("winner"), drain);
        mockOracle.setPrice(PAIR, PRICE * 3);
        vault.refreshPnlSnapshot(EMPTY);
        assertEq(vault.totalAssets(), 0);
        _callViews(type(uint128).max);

        // A Vault with no shares
        Vault empty = new Vault(address(usdc), owner, address(tradingStorage), address(mockOracle));
        assertEq(empty.totalSupply(), 0);
        empty.totalAssets();
        empty.convertToShares(type(uint128).max);
        empty.convertToAssets(type(uint128).max);
        empty.previewDeposit(type(uint128).max);
        empty.previewMint(type(uint128).max);
    }

    function _callViews(uint256 _amount) internal view {
        vault.totalAssets();
        vault.convertToShares(_amount);
        vault.convertToAssets(_amount);
        vault.previewDeposit(_amount);
        vault.previewMint(_amount);
        vault.previewRedeem(_amount);
        vault.previewWithdraw(_amount);
        vault.maxDeposit(lp);
        vault.maxMint(lp);
        vault.maxWithdraw(lp);
        vault.maxRedeem(lp);
        vault.collateralizationRatio();
        vault.realisedCollateralizationRatio();
    }

    /*//////////////////////////////////////////////////////////////
                        sUSDC WITH ESCROW
    //////////////////////////////////////////////////////////////*/

    function test_Metadata() public view {
        assertEq(vault.name(), "Synthetic Liquidity Token");
        assertEq(vault.symbol(), "sUSDC");
        assertEq(vault.decimals(), 18);
        assertEq(vault.asset(), address(usdc));
    }

    /**
     * @notice Escrowed shares stay in totalSupply and follow the NAV, but their owner cannot move them, neither
     *         directly nor through an allowance
     */
    function testFuzz_EscrowedSharesFollowNavAndCannotMove(uint256 _bps, uint256 _donation) public {
        uint256 total = vault.balanceOf(lp);
        uint256 escrowed = (total * bound(_bps, 1, 9_999)) / 10_000;
        uint256 supply = vault.totalSupply();
        vm.prank(lp);
        vault.requestWithdrawal(escrowed);

        assertEq(vault.totalSupply(), supply, "escrow changed the supply");
        assertEq(vault.balanceOf(address(vault)), escrowed, "escrow not held by the Vault");
        assertEq(vault.balanceOf(lp), total - escrowed);

        uint256 valueBefore = vault.convertToAssets(escrowed);
        usdc.mint(address(vault), bound(_donation, 1 * 10 ** 6, LP_DEPOSIT));
        assertGt(vault.convertToAssets(escrowed), valueBefore, "escrowed shares did not follow the NAV");

        uint256 free = vault.balanceOf(lp);
        vm.prank(lp);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        vault.transfer(other, free + 1);

        vm.prank(lp);
        vault.approve(other, type(uint256).max);
        vm.prank(other);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        vault.transferFrom(lp, other, free + 1);

        vm.prank(other);
        vault.transferFrom(lp, other, free);
        assertEq(vault.balanceOf(lp), 0);
    }

    /// @notice A new request returns the previous escrow first, so an LP never has two escrows
    function test_NewRequestReplacesEscrow() public {
        uint256 total = vault.balanceOf(lp);
        vm.startPrank(lp);
        vault.requestWithdrawal(total / 2);
        vault.requestWithdrawal(total / 4);
        vm.stopPrank();
        assertEq(vault.balanceOf(address(vault)), total / 4);
        assertEq(vault.balanceOf(lp), total - total / 4);
    }
}
