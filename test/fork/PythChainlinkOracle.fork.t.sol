// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {RegressionUSDC} from "../regression/RegressionBase.sol";

/**
 * @title PythChainlinkOracleForkTest
 * @notice Fork tests against Arbitrum One (chain 42161) at a pinned block, with the real Pyth, Chainlink and
 *         sequencer uptime contracts. No network call other than the fork RPC: no Hermes, no ffi.
 * @dev The default block 504,522,171 (2026-09-12 21:25:49 UTC) contains an on-chain Pyth update of BTC/USD
 *      and ETH/USD (tx 0x0c93c1c31a58b7c97eb3a3a2541aa38dd331e9c0bf1e7e0a154bf25b40a84349) published 1 s
 *      earlier, so the stored prices are fresh at that block and getPrice can run with empty update data.
 *      RECORDED_UPDATE is the signed update data of that transaction, taken from its calldata; it is used to
 *      exercise verification and the update fee with real data.
 *      Skipped when FORK_RPC_URL is not set. The RPC must serve historical state (archive).
 *      Run: FORK_RPC_URL=<arbitrum-rpc> forge test --match-path "test/fork/*" -vv
 *      Pin another block with FORK_BLOCK_NUMBER; the tests that need fresh stored prices assume a block like
 *      the default one.
 */
contract PythChainlinkOracleForkTest is Test {
    PythChainlinkOracle oracle;

    // Arbitrum One contracts, checked for code in test_Fork_AddressesHaveCode
    address constant PYTH = 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C;
    /// @dev Implementation set by the Pyth Core upgrade: Upgraded event at block 498,630,307 (2026-08-26 16:11:30 UTC)
    address constant PYTH_CORE_IMPLEMENTATION = 0x8391e5e91d27D1d89139bc94b27Ed8B67a17a6cB;
    address constant CHAINLINK_BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant SEQUENCER_UPTIME_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    // Pyth feed IDs (same on every chain)
    bytes32 constant PYTH_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant PYTH_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    uint256 constant DEFAULT_FORK_BLOCK = 504_522_171;
    uint64 constant RECORDED_PUBLISH_TIME = 1_789_248_348;
    bytes32 constant ERC1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 constant PAIR_BTC = 0;
    uint256 constant PAIR_ETH = 1;
    /// @dev Heartbeat of both 8-decimal proxies in Chainlink's reference data for Arbitrum One
    uint32 constant CHAINLINK_HEARTBEAT = 1755;

    bytes constant RECORDED_UPDATE = hex"504e415501000000012401000000010300f73f34a4520e5ad6d3901ba454998b6cd547caef065eef938ddb437e725a23b05de819d88428ce1092c5ba29123de8"
        hex"5235002d4a3599a46a42691d356e4bee38010166a8fb324258ab8fc559d8a05e1afd918a023dc6e4391f7ff2cf08c53de25118229b2e5707f450c6e41399420a"
        hex"a9a50baf7c0f017e2e781762d03b9ea28041670002be52d39fd92a8eb26285411a2c8d1968409a3c2474eef8de9e8d9b88e20ae3e504ffb5f88f7f4070beba70"
        hex"ebb9e8c08239cc5412e48d21088a885babe3706eb5006aa5c35c00000000001a507974686e6574507974686e6574507974686e6574507974686e657450797468"
        hex"0000000854f343300041555756000000000854f3433000000000146c972e859e0f5c656265f03ad3dc4949384c6a04005500e62df6c8b4a85fe1a67db44dc12d"
        hex"e5db330f7ac66b72dc658afedf0f4a415b4300000704d682d211000000005de5c2cffffffff8000000006aa5c35c000000006aa5c35b00000704978ec5e00000"
        hex"00004be0251d0ca41e2f6782cf07cf33d3136fedaaa0a8d15e44de7ed4cb9a4488b2097c1cc9bbdaeee08e4ff310d3033e935bef07ff11d7a5c7f53aa4daa473"
        hex"6e8c9a37ab9dd03c2dd3a2849f0eed5055db45395c04f07e5476bccc90b6a9b8abb5e26cb23a231645b154a11b551ccc7150c59d12de937f4e3cc20b610a623c"
        hex"db09816adf9cf11a682de96e3188ff502e2ea24843ccbe63406cd39c232ef6ac1b1edb8620d0ee4e7d40017433494d579c82b82316145dc1624d43c6aff4d771"
        hex"4f5874550e5b953a7cd313f3675ac86719aa63181eff1a328be9ba5e85c56a5fbcb0510592b8e40635c67af326bf719d261ac8ecc887f3005500ff61491a9311"
        hex"12ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace0000003ac1bf8c230000000001a8d17ffffffff8000000006aa5c35c000000006aa5c35b0000"
        hex"003aba5a65a00000000002397e4f0cd396374dd7a5db20ecb95f5e33d8f14ed3ae24f67ed4cb9a4488b2097c1cc9bbdaeee08e4ff310d3033e935bef07ff11d7"
        hex"a5c7f53aa4daa4736e8c9a37ab9dd03c2dd3a2849f0eed5055db45395c04f07e5476bccc90b6a9b8abb5e26cb23a231645b154a11b551ccc7150c59d12de937f"
        hex"4e3cc20b610a623cdb09816adf9cf11a682de96e3188ff502e2ea24843ccbe63406cd39c232ef6ac1b1edb8620d0ee4e7d40017433494d579c82b82316145dc1"
        hex"624d43c6aff4d7714f5874550e5b953a7cd313f3675ac86719aa63181eff1a328be9ba5e85c56a5fbcb0510592b8e40635c67af326bf719d261ac8ecc887f300"
        hex"5500ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d000000025cc611720000000000123b4bfffffff8000000006aa5c35c0000"
        hex"00006aa5c35b000000025ccba5a8000000000010f6df0c0e7f301bc2a63411b598f1269d6eebc88cf231c465b112d6c58a33409fbfbd794fb616d2731a77a644"
        hex"dbf44d23333a94ff04fee7d89113b31bea02f137ab9dd03c2dd3a2849f0eed5055db45395c04f07e5476bccc90b6a9b8abb5e26cb23a231645b154a11b551ccc"
        hex"7150c59d12de937f4e3cc20b610a623cdb09816adf9cf11a682de96e3188ff502e2ea24843ccbe63406cd39c232ef6ac1b1edb8620d0ee4e7d40017433494d57"
        hex"9c82b82316145dc1624d43c6aff4d7714f5874550e5b953a7cd313f3675ac86719aa63181eff1a328be9ba5e85c56a5fbcb0510592b8e40635c67af326bf719d"
        hex"261ac8ecc887f30055002f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f00000010e94ba3e60000000000a8398afffffff80000"
        hex"00006aa5c35c000000006aa5c35b00000010ec25cce80000000000aba7090caa8b706ec40ddbf941165968688bd9364663d5daee536f226511a2440f31a744b4"
        hex"73b20e9d7bbf18f4a7d52ab86c6ee834ba61015d360244620cffae100c3ed885d6bf862b19611ac1ea37f26d84c26d7e5476bccc90b6a9b8abb5e26cb23a2316"
        hex"45b154a11b551ccc7150c59d12de937f4e3cc20b610a623cdb09816adf9cf11a682de96e3188ff502e2ea24843ccbe63406cd39c232ef6ac1b1edb8620d0ee4e"
        hex"7d40017433494d579c82b82316145dc1624d43c6aff4d7714f5874550e5b953a7cd313f3675ac86719aa63181eff1a328be9ba5e85c56a5fbcb0510592b8e406"
        hex"35c67af326bf719d261ac8ecc887f3";

    address owner = makeAddr("owner");
    bool forked;

    modifier skipIfNoFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory forkUrl = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) return;

        vm.createSelectFork(forkUrl, vm.envOr("FORK_BLOCK_NUMBER", DEFAULT_FORK_BLOCK));
        forked = true;

        vm.startPrank(owner);
        oracle = new PythChainlinkOracle(PYTH, SEQUENCER_UPTIME_FEED, owner);
        oracle.setPairFeed(PAIR_BTC, PYTH_BTC_USD, CHAINLINK_BTC_USD, CHAINLINK_HEARTBEAT);
        oracle.setPairFeed(PAIR_ETH, PYTH_ETH_USD, CHAINLINK_ETH_USD, CHAINLINK_HEARTBEAT);
        vm.stopPrank();

        vm.deal(address(this), 10 ether);
    }

    function _empty() internal pure returns (bytes[] memory) {
        return new bytes[](0);
    }

    function _recorded() internal pure returns (bytes[] memory data) {
        data = new bytes[](1);
        data[0] = RECORDED_UPDATE;
    }

    function _chainlink18(address _feed) internal view returns (uint256) {
        (, int256 answer,,,) = AggregatorV3Interface(_feed).latestRoundData();
        return uint256(answer) * 1e10;
    }

    /*//////////////////////////////////////////////////////////////
                       CHAIN AND CONTRACT CHECKS
    //////////////////////////////////////////////////////////////*/

    function test_Fork_ChainIsArbitrumOne() public skipIfNoFork {
        assertEq(block.chainid, 42_161);
    }

    function test_Fork_AddressesHaveCode() public skipIfNoFork {
        assertGt(PYTH.code.length, 0, "Pyth");
        assertGt(PYTH_CORE_IMPLEMENTATION.code.length, 0, "Pyth implementation");
        assertGt(CHAINLINK_BTC_USD.code.length, 0, "Chainlink BTC/USD");
        assertGt(CHAINLINK_ETH_USD.code.length, 0, "Chainlink ETH/USD");
        assertGt(SEQUENCER_UPTIME_FEED.code.length, 0, "sequencer uptime feed");
    }

    /// @notice The pinned block runs the Pyth Core contract installed on 2026-08-26
    function test_Fork_PythProxyRunsUpgradedImplementation() public skipIfNoFork {
        address implementation = address(uint160(uint256(vm.load(PYTH, ERC1967_IMPLEMENTATION_SLOT))));
        assertEq(implementation, PYTH_CORE_IMPLEMENTATION);

        (bool ok, bytes memory ret) = PYTH.staticcall(abi.encodeWithSignature("version()"));
        assertTrue(ok, "version() reverted");
        console2.log("Pyth version:", abi.decode(ret, (string)));
    }

    function test_Fork_ChainlinkDecimals_Are8() public skipIfNoFork {
        assertEq(AggregatorV3Interface(CHAINLINK_BTC_USD).decimals(), 8);
        assertEq(AggregatorV3Interface(CHAINLINK_ETH_USD).decimals(), 8);
    }

    function test_Fork_PythExponent_IsMinus8() public skipIfNoFork {
        assertEq(IPyth(PYTH).getPriceUnsafe(PYTH_BTC_USD).expo, -8);
        assertEq(IPyth(PYTH).getPriceUnsafe(PYTH_ETH_USD).expo, -8);
    }

    /*//////////////////////////////////////////////////////////////
                        STORED PRICE (EMPTY UPDATE)
    //////////////////////////////////////////////////////////////*/

    function test_Fork_GetPrice_BTC() public skipIfNoFork {
        (uint128 price,) = oracle.getPrice(PAIR_BTC, _empty());
        PythStructs.Price memory raw = IPyth(PYTH).getPriceUnsafe(PYTH_BTC_USD);

        assertEq(price, uint256(uint64(raw.price)) * 1e10, "not the stored Pyth price in 18 decimals");
        assertGt(price, 10_000 * 1e18, "BTC price too low");
        assertLt(price, 500_000 * 1e18, "BTC price too high");
        console2.log("BTC/USD (18 dec):", price);
        console2.log("price age (s):", block.timestamp - raw.publishTime);
    }

    function test_Fork_GetPrice_ETH() public skipIfNoFork {
        (uint128 price,) = oracle.getPrice(PAIR_ETH, _empty());
        assertGt(price, 500 * 1e18, "ETH price too low");
        assertLt(price, 50_000 * 1e18, "ETH price too high");
    }

    function test_Fork_PythChainlinkDeviation() public skipIfNoFork {
        (uint128 btc,) = oracle.getPrice(PAIR_BTC, _empty());
        (uint128 eth,) = oracle.getPrice(PAIR_ETH, _empty());
        uint256 clBtc = _chainlink18(CHAINLINK_BTC_USD);
        uint256 clEth = _chainlink18(CHAINLINK_ETH_USD);

        uint256 btcDevBps = ((btc > clBtc ? btc - clBtc : clBtc - btc) * 10_000) / clBtc;
        uint256 ethDevBps = ((eth > clEth ? eth - clEth : clEth - eth) * 10_000) / clEth;
        console2.log("BTC deviation (bps):", btcDevBps);
        console2.log("ETH deviation (bps):", ethDevBps);
        assertLe(btcDevBps, 300);
        assertLe(ethDevBps, 300);
    }

    function test_Fork_ConfidenceWithinBounds() public skipIfNoFork {
        PythStructs.Price memory btc = IPyth(PYTH).getPriceUnsafe(PYTH_BTC_USD);
        uint256 confBps = (uint256(btc.conf) * 10_000) / uint256(uint64(btc.price));
        console2.log("BTC confidence (bps):", confBps);
        assertLt(confBps, 200);
    }

    function test_Fork_RevertOnUnconfiguredPair() public skipIfNoFork {
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.PairFeedNotSet.selector, 999));
        oracle.getPrice(999, _empty());
    }

    function test_Fork_PairFeedConfig() public skipIfNoFork {
        PythChainlinkOracle.PairFeed memory feed = oracle.getPairFeed(PAIR_BTC);
        assertEq(feed.pythFeedId, PYTH_BTC_USD);
        assertEq(feed.chainlinkFeed, CHAINLINK_BTC_USD);
        assertEq(feed.chainlinkHeartbeat, CHAINLINK_HEARTBEAT);
        assertTrue(feed.active);
    }

    /// @notice Once the stored price is older than maxPriceAge, getPrice reverts
    function test_Fork_StalenessDetected_AfterWarp() public skipIfNoFork {
        oracle.getPrice(PAIR_BTC, _empty());
        uint256 publishTime = IPyth(PYTH).getPriceUnsafe(PYTH_BTC_USD).publishTime;

        vm.warp(publishTime + oracle.maxPriceAge() + 1);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.StalePrice.selector, PYTH_BTC_USD, publishTime, block.timestamp));
        oracle.getPrice(PAIR_BTC, _empty());
    }

    /*//////////////////////////////////////////////////////////////
                    RECORDED SIGNED UPDATE (NO HERMES)
    //////////////////////////////////////////////////////////////*/

    /// @notice Arbitrum charges no Pyth update fee at the pinned block, for empty or real update data
    function test_Fork_UpdateFee_IsZero() public skipIfNoFork {
        assertEq(IPyth(PYTH).getUpdateFee(_empty()), 0);
        assertEq(IPyth(PYTH).getUpdateFee(_recorded()), 0);
    }

    /// @notice The recorded update verifies against the upgraded contract and carries the stored BTC price
    function test_Fork_RecordedUpdate_Verifies() public skipIfNoFork {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = PYTH_BTC_USD;
        ids[1] = PYTH_ETH_USD;
        PythStructs.PriceFeed[] memory feeds = IPyth(PYTH).parsePriceFeedUpdates(_recorded(), ids, RECORDED_PUBLISH_TIME, RECORDED_PUBLISH_TIME);

        assertEq(feeds[0].price.publishTime, RECORDED_PUBLISH_TIME);
        assertEq(feeds[0].price.price, IPyth(PYTH).getPriceUnsafe(PYTH_BTC_USD).price);
        assertEq(feeds[1].price.publishTime, RECORDED_PUBLISH_TIME);
    }

    /// @notice getPrice with real signed data: updatePriceFeeds runs and the surplus ETH is refunded
    function test_Fork_GetPrice_WithRecordedUpdate_RefundsSurplus() public skipIfNoFork {
        uint256 balanceBefore = address(this).balance;
        (uint128 price,) = oracle.getPrice{value: 0.01 ether}(PAIR_BTC, _recorded());
        assertGt(price, 0);
        assertEq(address(this).balance, balanceBefore, "surplus not refunded with a zero fee");
    }

    /*//////////////////////////////////////////////////////////////
                        SEQUENCER UPTIME FEED
    //////////////////////////////////////////////////////////////*/

    function test_Fork_Sequencer_IsUpPastGracePeriod() public skipIfNoFork {
        (, int256 answer, uint256 startedAt,,) = AggregatorV3Interface(SEQUENCER_UPTIME_FEED).latestRoundData();
        assertEq(answer, 0, "sequencer reported down");
        assertGt(block.timestamp - startedAt, oracle.SEQUENCER_GRACE_PERIOD(), "inside grace period");
    }

    function test_Fork_Sequencer_DownReverts() public skipIfNoFork {
        _mockSequencer(1, block.timestamp - 1 days);
        vm.expectRevert(PythChainlinkOracle.SequencerDown.selector);
        oracle.getPrice(PAIR_BTC, _empty());
    }

    /// @notice During the grace period opening is refused and prices are still served for other actions
    function test_Fork_Sequencer_GracePeriodBlocksOpeningOnly() public skipIfNoFork {
        uint256 upSince = block.timestamp - 100;
        _mockSequencer(0, upSince);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.SequencerGracePeriodNotOver.selector, upSince, block.timestamp));
        oracle.checkOpenAllowed();
        (uint128 price,) = oracle.getPrice(PAIR_BTC, _empty());
        assertGt(price, 0, "price refused during the grace period");
    }

    function _mockSequencer(int256 _answer, uint256 _startedAt) internal {
        vm.mockCall(
            SEQUENCER_UPTIME_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), _answer, _startedAt, _startedAt, uint80(1))
        );
    }

    /*//////////////////////////////////////////////////////////////
                    END TO END THROUGH THE ENGINE
    //////////////////////////////////////////////////////////////*/

    RegressionUSDC usdc;
    TradingStorage tradingStorage;
    Vault vault;
    TradingEngine engine;

    /// @dev Storage, Vault and engine on the real oracle, with 1,000,000 USDC deposited by this contract
    function _deployEngineStack() internal {
        usdc = new RegressionUSDC();
        vm.startPrank(owner);
        tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner, address(tradingStorage), address(oracle));
        engine = new TradingEngine(
            address(tradingStorage), address(vault), address(oracle), address(usdc), makeAddr("treasury"), address(new MockSpreadManager(5)), owner
        );
        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));
        tradingStorage.addPair("BTC/USD", 100, 10_000_000 * 1e18);
        vm.stopPrank();

        usdc.mint(address(this), 1_000_100 * 10 ** 6);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 * 10 ** 6, address(this));
        usdc.approve(address(engine), type(uint256).max);
    }

    /// @notice Open and close a 10x BTC long through TradingEngine on the real oracle stack
    function test_Fork_TradingEngine_OpenAndClose() public skipIfNoFork {
        _deployEngineStack();
        (uint128 oraclePrice,) = oracle.getPrice(PAIR_BTC, _empty());
        uint32 tradeId = engine.openTrade(uint16(PAIR_BTC), true, 100 * 10 ** 6, 10, oraclePrice, 100, 0, 0, _empty());
        assertEq(tradingStorage.getTrade(tradeId).openPrice, (uint256(oraclePrice) * 10_005) / 10_000);

        engine.closeTrade(tradeId, oraclePrice, 100, _empty());
        assertEq(tradingStorage.getTrade(tradeId).user, address(0));
    }

    /// @notice During the sequencer grace period a position opened before it closes through the engine; opening reverts
    function test_Fork_TradingEngine_GracePeriodClosesButDoesNotOpen() public skipIfNoFork {
        _deployEngineStack();
        (uint128 oraclePrice,) = oracle.getPrice(PAIR_BTC, _empty());
        uint32 tradeId = engine.openTrade(uint16(PAIR_BTC), true, 100 * 10 ** 6, 10, oraclePrice, 100, 0, 0, _empty());

        uint256 upSince = block.timestamp - 100;
        _mockSequencer(0, upSince);
        engine.closeTrade(tradeId, oraclePrice, 100, _empty());
        assertEq(tradingStorage.getTrade(tradeId).user, address(0), "close refused during the grace period");

        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.SequencerGracePeriodNotOver.selector, upSince, block.timestamp));
        engine.openTrade(uint16(PAIR_BTC), true, 100 * 10 ** 6, 10, oraclePrice, 100, 0, 0, _empty());
    }

    receive() external payable {}
}
