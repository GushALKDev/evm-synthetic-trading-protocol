// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract RegressionUSDC is ERC20 {
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
 * @title RegressionBase
 * @author GushALKDev
 * @notice Shared setup for the round 2 regression tests: TradingEngine wired to TradingStorage, the Vault,
 *         MockOracle and MockSpreadManager, with 10M USDC of LP liquidity, as in TradingEngine.t.sol.
 */
abstract contract RegressionBase is Test {
    TradingEngine engine;
    TradingStorage tradingStorage;
    Vault vault;
    RegressionUSDC usdc;
    MockOracle mockOracle;
    MockSpreadManager mockSpreadManager;

    address owner = makeAddr("owner");
    address treasuryAddr = makeAddr("treasury");
    address lp = makeAddr("lp");

    uint16 constant PAIR = 0;
    uint128 constant ORACLE_PRICE = 50_000 * 1e18;
    uint256 constant LP_SEED = 10_000_000 * 10 ** 6;
    bytes[] EMPTY_UPDATE;

    function setUp() public virtual {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        mockOracle = new MockOracle();
        mockOracle.setPrice(PAIR, ORACLE_PRICE);
        mockSpreadManager = new MockSpreadManager(5);

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner);
        engine = new TradingEngine(address(tradingStorage), address(vault), address(mockOracle), address(usdc), treasuryAddr, address(mockSpreadManager), owner);
        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));
        tradingStorage.addPair("BTC/USD", 100, 10_000_000 * 1e18);
        vm.stopPrank();

        usdc.mint(lp, LP_SEED);
        vm.startPrank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(LP_SEED, lp);
        vm.stopPrank();
    }

    function _fund(address _user, uint256 _amount) internal {
        usdc.mint(_user, _amount);
        vm.prank(_user);
        usdc.approve(address(engine), type(uint256).max);
    }

    /// @dev Open at the current oracle price with a 1% slippage band and no TP/SL
    function _open(address _user, bool _isLong, uint64 _collateral, uint16 _leverage) internal returns (uint32 tradeId) {
        uint128 price = mockOracle.peekPrice(PAIR);
        vm.prank(_user);
        tradeId = engine.openTrade(PAIR, _isLong, _collateral, _leverage, price, 100, 0, 0, EMPTY_UPDATE);
    }

    /// @dev Close at the current oracle price with a 1% slippage band
    function _close(address _user, uint256 _tradeId) internal {
        uint128 price = mockOracle.peekPrice(PAIR);
        vm.prank(_user);
        engine.closeTrade(_tradeId, price, 100, EMPTY_UPDATE);
    }
}
