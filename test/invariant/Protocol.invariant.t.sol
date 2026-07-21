// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {ProtocolHandler} from "./handlers/ProtocolHandler.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract MockUSDC is ERC20 {
    function name() public pure override returns (string memory) {
        return "USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "USDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title ProtocolInvariantTest
 * @author GushALKDev
 * @notice Roadmap 12.3 — properties that must hold after ANY sequence of protocol actions.
 * @dev All state transitions go through ProtocolHandler, which only issues valid calls. The Vault is
 *      seeded with LP liquidity so winning traders can actually be paid, otherwise payouts would
 *      revert and the interesting states would never be reached.
 */
contract ProtocolInvariantTest is StdInvariant, Test {
    TradingEngine engine;
    TradingStorage tradingStorage;
    Vault vault;
    MockUSDC usdc;
    MockOracle oracle;
    MockSpreadManager spreadManager;
    ProtocolHandler handler;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address lp = makeAddr("lp");

    uint128 constant MAX_OI = 10_000_000 * 1e18;

    function setUp() public {
        // Staleness/funding math needs a non-trivial starting timestamp
        vm.warp(1_000_000);

        usdc = new MockUSDC();
        oracle = new MockOracle();
        oracle.setPrice(0, 50_000 * 1e18);
        spreadManager = new MockSpreadManager(5);

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner);
        engine = new TradingEngine(
            address(tradingStorage),
            address(vault),
            address(oracle),
            address(usdc),
            treasury,
            address(spreadManager),
            owner
        );
        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));
        tradingStorage.addPair("BTC/USD", 100, MAX_OI);
        vm.stopPrank();

        // Seed LP liquidity so profitable traders can be paid out
        usdc.mint(lp, 1_000_000 * 10 ** 6);
        vm.startPrank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 * 10 ** 6, lp);
        vm.stopPrank();

        handler = new ProtocolHandler(engine, tradingStorage, vault, oracle, usdc);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice 12.3.1 — The Vault never reports more assets than the USDC it actually holds
     * @dev totalAssets() is balance-based, so this pins it to reality: a drift would mean the Vault
     *      is promising LPs liquidity that is not there.
     */
    function invariant_TotalAssetsBackedByBalance() public view {
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)), "totalAssets diverged from USDC balance");
    }

    /**
     * @notice 12.3.2 — Open interest never exceeds the pair's configured maxOI
     * @dev Long and short OI are tracked separately; the cap applies to each side as enforced in
     *      TradingEngine._validateMaxOI.
     */
    function invariant_OpenInterestWithinMax() public view {
        uint128 maxOI = tradingStorage.getPair(0).maxOI;
        assertLe(tradingStorage.getOpenInterestLong(0), maxOI, "long OI exceeded maxOI");
        assertLe(tradingStorage.getOpenInterestShort(0), maxOI, "short OI exceeded maxOI");
    }

    /**
     * @notice 12.3.3 — Share price is strictly positive while shares are outstanding
     * @dev A zero share price would mean LP shares became worthless and would break both deposit
     *      and withdrawal math (division by zero / infinite mint).
     */
    function invariant_SharePricePositive() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;
        assertGt(vault.convertToAssets(1e18), 0, "share price fell to zero");
    }

    /**
     * @notice Custody — TradingStorage holds at least the collateral owed to all open trades
     * @dev Trader collateral lives in TradingStorage, never in the Vault. If its balance dipped below
     *      the sum of open positions' collateral, some trader could not be paid on close: the Vault
     *      would have absorbed funds that were never LP liquidity.
     */
    function invariant_StorageCoversOpenCollateral() public view {
        assertGe(
            usdc.balanceOf(address(tradingStorage)),
            handler.ghostOpenCollateral(),
            "TradingStorage cannot cover open trade collateral"
        );
    }

    /**
     * @notice Custody — shares are never created without assets backing them
     * @dev The mirror of the share-price invariant: a non-zero share supply must always be backed by
     *      a non-zero asset balance. Zero assets against live shares is the insolvency end-state, and
     *      would let the next depositor mint against an empty Vault.
     */
    function invariant_SharesBackedByAssets() public view {
        if (vault.totalSupply() == 0) return;
        assertGt(vault.totalAssets(), 0, "shares outstanding with zero backing assets");
    }

    /// @notice Surfaces how often each handler action actually ran, to catch a silently idle suite
    function invariant_CallSummary() public view {
        console.log("deposit    :", handler.calls("deposit"));
        console.log("openTrade  :", handler.calls("openTrade"));
        console.log("closeTrade :", handler.calls("closeTrade"));
        console.log("liquidate  :", handler.calls("liquidate"));
        console.log("movePrice  :", handler.calls("movePrice"));
        console.log("warp       :", handler.calls("warp"));
        console.log("open trades:", handler.openTradeCount());
        console.log("settled liq:", handler.ghostLiquidations());
    }
}
