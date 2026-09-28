// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {SpreadManager} from "../../src/SpreadManager.sol";
import {AssistantFund} from "../../src/AssistantFund.sol";
import {SolvencyManager} from "../../src/SolvencyManager.sol";
import {BondDepository} from "../../src/BondDepository.sol";
import {SynthToken} from "../../src/SynthToken.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {RegressionUSDC} from "../regression/RegressionBase.sol";

/**
 * @title GasBenchmarks
 * @author GushALKDev
 * @notice Gas of one successful call per entry point, recorded with vm.snapshotGasLastCall into
 *         snapshots/<group>.json. Kept out of the correctness suite: the default profile skips test/gas.
 *         Run: FOUNDRY_PROFILE=gas forge test
 * @dev Contracts are wired as in DeployLib, with the real PythChainlinkOracle (on MockPyth, plus a sequencer
 *      uptime feed as on Arbitrum) and the real SpreadManager. MockPyth does not verify Wormhole signatures,
 *      so the Pyth update itself costs less than on a live chain. Every measured call succeeds; setup calls are
 *      not measured. Each benchmark measures a warm pair: one position is already open.
 */
contract GasBenchmarks is Test {
    TradingEngine engine;
    TradingStorage tradingStorage;
    Vault vault;
    PythChainlinkOracle oracle;
    AssistantFund assistantFund;
    SolvencyManager solvencyManager;
    BondDepository bondDepository;
    MockPyth mockPyth;
    MockChainlinkFeed chainlink;
    RegressionUSDC usdc;

    address owner = makeAddr("owner");
    address trader = makeAddr("trader");
    address lp = makeAddr("lp");
    address keeper = makeAddr("keeper");

    bytes32 constant FEED_ID = bytes32(uint256(1));
    uint16 constant PAIR = 0;
    int64 constant PRICE = 50_000 * 1e8;
    uint128 constant PRICE18 = 50_000 * 1e18;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new RegressionUSDC();
        mockPyth = new MockPyth(60, 1);
        chainlink = new MockChainlinkFeed(8);
        chainlink.setAnswer(PRICE);
        MockChainlinkFeed sequencer = new MockChainlinkFeed(0);
        sequencer.setStartedAt(block.timestamp - 1 days);

        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner);
        oracle = new PythChainlinkOracle(address(mockPyth), address(sequencer), owner);
        SpreadManager spreadManager = new SpreadManager(5, 3e5, 100, 100, 5000, owner, owner);
        assistantFund = new AssistantFund(address(usdc), address(vault), 1_000_000 * 10 ** 6, owner);
        SynthToken synth = new SynthToken(owner);
        bondDepository = new BondDepository(address(usdc), address(vault), address(synth), 500, owner);
        engine =
            new TradingEngine(address(tradingStorage), address(vault), address(oracle), address(usdc), address(assistantFund), address(spreadManager), owner);
        solvencyManager = new SolvencyManager(address(vault), address(assistantFund), address(bondDepository), owner);
        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));
        synth.setMinter(address(bondDepository));
        assistantFund.setSolvencyManager(address(solvencyManager));
        bondDepository.setSolvencyManager(address(solvencyManager));
        tradingStorage.addPair("BTC/USD", 100, 10_000_000 * 1e18);
        oracle.setPairFeed(PAIR, FEED_ID, address(chainlink), 3600);
        vm.stopPrank();

        usdc.mint(lp, 2_000_000 * 10 ** 6);
        vm.prank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(lp);
        vault.deposit(1_000_000 * 10 ** 6, lp);

        usdc.mint(trader, 1_000_000 * 10 ** 6);
        vm.prank(trader);
        usdc.approve(address(engine), type(uint256).max);
        vm.deal(trader, 1 ether);
        vm.deal(keeper, 1 ether);

        _open(true, 0, 0); // warm the pair: funding timestamp, OI and storage slots already written
    }

    function _update(int64 _price) internal view returns (bytes[] memory data) {
        data = new bytes[](1);
        data[0] = mockPyth.createPriceFeedUpdateData(FEED_ID, _price, 10 * 1e8, -8, _price, 10 * 1e8, uint64(block.timestamp), uint64(block.timestamp - 1));
    }

    function _setPrice(int64 _price) internal {
        vm.warp(block.timestamp + 1);
        chainlink.setAnswer(_price);
        chainlink.setUpdatedAt(block.timestamp);
    }

    function _open(bool _isLong, uint128 _tp, uint128 _sl) internal returns (uint32 tradeId) {
        bytes[] memory data = _update(PRICE);
        vm.prank(trader);
        tradeId = engine.openTrade{value: 1}(PAIR, _isLong, 1_000 * 10 ** 6, 10, PRICE18, 100, _tp, _sl, data);
    }

    function test_Gas_OpenTrade() public {
        _open(true, 55_000 * 1e18, 45_000 * 1e18);
        vm.snapshotGasLastCall("TradingEngine", "openTrade");
    }

    function test_Gas_CloseTrade() public {
        uint32 tradeId = _open(true, 0, 0);
        _setPrice(51_000 * 1e8);
        bytes[] memory data = _update(51_000 * 1e8);
        vm.prank(trader);
        engine.closeTrade{value: 1}(tradeId, 51_000 * 1e18, 100, data);
        vm.snapshotGasLastCall("TradingEngine", "closeTrade");
    }

    function test_Gas_Liquidate() public {
        uint32 tradeId = _open(true, 0, 0);
        _setPrice(45_000 * 1e8); // -10% at 10x
        bytes[] memory data = _update(45_000 * 1e8);
        vm.prank(keeper);
        engine.liquidate{value: 1}(tradeId, data);
        vm.snapshotGasLastCall("TradingEngine", "liquidate");
    }

    function test_Gas_ExecuteLimit() public {
        uint32 tradeId = _open(true, 51_000 * 1e18, 0);
        _setPrice(51_500 * 1e8);
        bytes[] memory data = _update(51_500 * 1e8);
        vm.prank(keeper);
        engine.executeLimit{value: 1}(tradeId, data);
        vm.snapshotGasLastCall("TradingEngine", "executeLimit");
    }

    function test_Gas_Deposit() public {
        vm.prank(lp);
        vault.deposit(10_000 * 10 ** 6, lp);
        vm.snapshotGasLastCall("Vault", "deposit");
    }

    function test_Gas_RequestWithdrawal() public {
        uint256 shares = vault.balanceOf(lp) / 2;
        vm.prank(lp);
        vault.requestWithdrawal(shares);
        vm.snapshotGasLastCall("Vault", "requestWithdrawal");
    }

    function test_Gas_ExecuteWithdrawal() public {
        uint256 shares = vault.balanceOf(lp) / 2;
        vm.prank(lp);
        vault.requestWithdrawal(shares);
        vm.warp(block.timestamp + 3 days);
        vm.prank(lp);
        vault.executeWithdrawal();
        vm.snapshotGasLastCall("Vault", "executeWithdrawal");
    }

    /// @notice checkAndAct at 90% CR with an empty reserve: opens a bonding round (the costliest path)
    function test_Gas_CheckAndAct() public {
        _drainVaultTo90Percent();
        solvencyManager.checkAndAct();
        vm.snapshotGasLastCall("SolvencyManager", "checkAndAct");
    }

    function test_Gas_Bond() public {
        _drainVaultTo90Percent();
        solvencyManager.checkAndAct();
        vm.prank(lp);
        usdc.approve(address(bondDepository), type(uint256).max);
        vm.prank(lp);
        bondDepository.bond(10_000 * 10 ** 6);
        vm.snapshotGasLastCall("BondDepository", "bond");
    }

    function _drainVaultTo90Percent() internal {
        vm.prank(address(engine));
        vault.sendPayout(makeAddr("winner"), 100_000 * 10 ** 6);
    }
}
