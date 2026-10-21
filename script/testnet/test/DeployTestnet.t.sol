// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

import {Deployed} from "../../Deploy.s.sol";
import {DeployTestnet} from "../DeployTestnet.s.sol";
import {SeedTrades} from "../SeedTrades.s.sol";
import {DemoPyth} from "../DemoPyth.sol";
import {TestnetFaucet, TestnetUSDC} from "../TestnetFaucet.sol";
import {TradingEngine} from "../../../src/TradingEngine.sol";
import {TradingStorage} from "../../../src/TradingStorage.sol";
import {Vault} from "../../../src/Vault.sol";
import {PythChainlinkOracle} from "../../../src/PythChainlinkOracle.sol";
import {BondDepository} from "../../../src/BondDepository.sol";
import {MockChainlinkFeed} from "../../../test/mocks/MockChainlinkFeed.sol";

/**
 * @dev Exposes the deployment file writer and the scripts' price helper to the tests
 */
contract DeployTestnetHarness is DeployTestnet {
    function exposedWriteDeployment(Deployed memory _d) external {
        _writeDeployment(_d);
    }

    function exposedMirrorPair(PythChainlinkOracle _oracle, DemoPyth _pyth, uint256 _pairIndex) external view returns (bytes memory) {
        return _mirrorPair(_oracle, _pyth, _pairIndex);
    }
}

/**
 * @title DeployTestnetTest
 * @notice Rehearses DeployTestnet.s.sol and SeedTrades.s.sol against mock Chainlink feeds, then drives the protocol the
 *         way the demo app does: each update entry is the pair's Chainlink answer with 5 bps of confidence, published at
 *         the latest block's timestamp, encoded here independently of DemoPyth's helper, and sent in the call that
 *         reads it with 1 wei per entry.
 * @dev Run with FOUNDRY_PROFILE=testnet. Outside a broadcast the deploy script writes no file.
 */
contract DeployTestnetTest is Test {
    address internal constant VISITOR = address(0xB0B);
    address internal constant KEEPER = address(0xC0FFEE);
    address internal constant GRIEFER = address(0xBAD);

    uint16 internal constant BTC = 0;
    uint16 internal constant ETH = 1;
    uint16 internal constant LINK = 2;

    MockChainlinkFeed internal btcFeed;
    MockChainlinkFeed internal ethFeed;
    MockChainlinkFeed internal linkFeed;

    DeployTestnetHarness internal script;
    Deployed internal d;
    TestnetFaucet internal faucet;
    TestnetUSDC internal usdc;
    DemoPyth internal pyth;
    address internal deployer;

    function setUp() public {
        vm.warp(1_800_000_000);
        btcFeed = _newFeed(100_000e8);
        ethFeed = _newFeed(4_000e8);
        linkFeed = _newFeed(20e8);

        vm.setEnv("BTC_CL_FEED", vm.toString(address(btcFeed)));
        vm.setEnv("ETH_CL_FEED", vm.toString(address(ethFeed)));
        vm.setEnv("LINK_CL_FEED", vm.toString(address(linkFeed)));

        script = new DeployTestnetHarness();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _newFeed(int256 _answer) internal returns (MockChainlinkFeed feed) {
        feed = new MockChainlinkFeed(8);
        feed.setAnswer(_answer);
    }

    /// @dev Moves a Chainlink answer and stamps it now, as a feed update does
    function _setPrice(MockChainlinkFeed _feed, int256 _answer) internal {
        _feed.setAnswer(_answer);
        _feed.setUpdatedAt(block.timestamp);
    }

    function _deploy() internal {
        d = script.run();
        (faucet, pyth, deployer,) = script.deployment();
        usdc = faucet.USDC();
    }

    function _deployAndSeed() internal {
        _deploy();
        SeedTrades seeder = new SeedTrades();
        seeder.seed(SeedTrades.Target({engine: d.engine, tradingStorage: d.tradingStorage, oracle: d.oracle, pyth: pyth, faucet: faucet}));
    }

    /// @dev What the app sends for one pair: the Chainlink answer, 5 bps of confidence, the given publishTime
    function _entry(uint256 _pairIndex, uint256 _publishTime) internal view returns (bytes memory) {
        PythChainlinkOracle.PairFeed memory f = d.oracle.getPairFeed(_pairIndex);
        (, int256 answer,,,) = MockChainlinkFeed(f.chainlinkFeed).latestRoundData();
        uint8 feedDecimals = MockChainlinkFeed(f.chainlinkFeed).decimals();
        PythStructs.PriceFeed memory feed;
        feed.id = f.pythFeedId;
        feed.price = PythStructs.Price({
            price: int64(answer), conf: uint64((uint256(answer) * 5) / 10_000), expo: -int32(uint32(feedDecimals)), publishTime: _publishTime
        });
        feed.emaPrice = feed.price;
        return abi.encode(feed);
    }

    /// @dev Engine calls carry one entry, for the trade's pair
    function _one(uint256 _pairIndex) internal view returns (bytes[] memory update) {
        update = new bytes[](1);
        update[0] = _entry(_pairIndex, block.timestamp);
    }

    /// @dev Vault refresh paths carry one entry per pair, so a pair whose OI changes before landing is covered
    function _all() internal view returns (bytes[] memory update) {
        uint256 count = d.tradingStorage.getPairsCount();
        update = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            update[i] = _entry(i, block.timestamp);
        }
    }

    function _price18(MockChainlinkFeed _feed) internal view returns (uint128) {
        (, int256 answer,,,) = _feed.latestRoundData();
        return uint128(uint256(answer) * 1e10);
    }

    /// @dev The execution price the app quotes for an open: oracle price with the open spread at the current OI
    function _openQuote(uint16 _pairIndex, bool _isLong, MockChainlinkFeed _feed) internal view returns (uint128) {
        uint256 spread = d.spreadManager.getSpreadBps(_pairIndex, d.tradingStorage.getOpenInterest(_pairIndex));
        uint256 price = _price18(_feed);
        return uint128(_isLong ? (price * (10_000 + spread)) / 10_000 : (price * (10_000 - spread)) / 10_000);
    }

    function _claimAndApprove(address _account, address _spender) internal {
        vm.startPrank(_account);
        faucet.claim();
        usdc.approve(_spender, type(uint256).max);
        vm.stopPrank();
        vm.deal(_account, 1 ether);
    }

    /// @dev A visitor's open, built and sent like the app's
    function _open(address _account, uint16 _pairIndex, bool _isLong, uint64 _collateral, uint16 _leverage, MockChainlinkFeed _feed)
        internal
        returns (uint32 tradeId)
    {
        bytes[] memory update = _one(_pairIndex);
        uint128 quote = _openQuote(_pairIndex, _isLong, _feed);
        vm.prank(_account);
        tradeId = d.engine.openTrade{value: 1 wei}(_pairIndex, _isLong, _collateral, _leverage, quote, 50, 0, 0, update);
    }

    /*//////////////////////////////////////////////////////////////
                              DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function test_run_deploysTheProtocolWithTheParametersOfDeploy() public {
        _deploy();

        // Deploy.s.sol parameters, read back so "no parameter changed" is checked rather than stated
        assertEq(d.spreadManager.baseSpreadBps(), 5, "base spread");
        assertEq(d.spreadManager.impactFactor(), 3e5, "impact factor");
        assertEq(d.spreadManager.volFactor(), 100, "vol factor");
        assertEq(d.spreadManager.maxSpreadBps(), 100, "max spread");
        assertEq(d.spreadManager.maxVolatilityChangeBps(), 5000, "max volatility change");
        assertEq(d.spreadManager.keeper(), deployer, "keeper");
        assertEq(d.assistantFund.targetCap(), 1_000_000e6, "reserve cap");
        assertEq(d.bondDepository.discountBps(), 500, "bond discount");

        // Wiring
        assertEq(d.tradingStorage.tradingEngine(), address(d.engine), "storage engine");
        assertEq(d.vault.tradingEngine(), address(d.engine), "vault engine");
        assertEq(address(d.vault.solvencyManager()), address(d.solvencyManager), "vault solvency manager");
        assertEq(d.synth.minter(), address(d.bondDepository), "synth minter");
        assertEq(d.assistantFund.solvencyManager(), address(d.solvencyManager), "fund solvency manager");
        assertEq(d.bondDepository.solvencyManager(), address(d.solvencyManager), "bond solvency manager");
        assertEq(d.engine.treasury(), address(d.assistantFund), "treasury");

        // Testnet differences
        assertEq(address(d.oracle.PYTH()), address(pyth), "oracle reads DemoPyth");
        assertEq(address(d.oracle.SEQUENCER_UPTIME_FEED()), address(0), "no sequencer feed on Base Sepolia");
        assertEq(d.oracle.maxPriceAge(), 30, "price age raised to the oracle's ceiling");
        assertEq(d.vault.ASSET(), address(usdc), "testnet USDC");
        assertEq(faucet.owner(), deployer, "faucet owner");
        assertEq(pyth.owner(), deployer, "DemoPyth owner");
    }

    function test_run_configuresThreePairsWithMatchingFeeds() public {
        _deploy();
        assertEq(d.tradingStorage.getPairsCount(), 3, "pairs");

        string[3] memory names = ["BTC/USD", "ETH/USD", "LINK/USD"];
        uint16[3] memory maxLeverage = [uint16(100), 100, 50];
        uint128[3] memory maxOI = [uint128(20_000_000e18), 20_000_000e18, 5_000_000e18];
        address[3] memory feeds = [address(btcFeed), address(ethFeed), address(linkFeed)];
        for (uint256 i; i < 3; ++i) {
            TradingStorage.Pair memory pair = d.tradingStorage.getPair(i);
            assertEq(pair.name, names[i], "name");
            assertEq(pair.maxLeverage, maxLeverage[i], "max leverage");
            assertEq(pair.maxOI, maxOI[i], "max OI");
            assertTrue(pair.isActive, "active");

            PythChainlinkOracle.PairFeed memory f = d.oracle.getPairFeed(i);
            assertEq(f.chainlinkFeed, feeds[i], "anchor");
            assertEq(f.chainlinkHeartbeat, 3_600, "anchor heartbeat");
            assertEq(pyth.chainlinkFeedOf(f.pythFeedId), feeds[i], "DemoPyth mirrors the oracle's anchor");
        }
        assertEq(d.oracle.getPairFeed(LINK).pythFeedId, 0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221, "LINK id");
    }

    function test_run_seedsLiquidityThatOnlyTheFaucetHolds() public {
        _deploy();
        assertEq(d.vault.balanceOf(address(faucet)), 1_000_000e18, "seed shares held by the faucet");
        assertEq(d.vault.totalSupply(), 1_000_000e18, "only the seed");
        assertEq(d.vault.totalAssets(), 1_000_000e6, "seed liquidity");
        assertEq(usdc.balanceOf(deployer), 0, "nothing left with the deployer");
    }

    /// @dev The smoke test is the only guard on a pair no seed trade prices (LINK)
    function test_run_revertsBeforeBroadcastingWhenAnAnchorIsStale() public {
        linkFeed.setUpdatedAt(block.timestamp - 3_601);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.ChainlinkStalePrice.selector, address(linkFeed), block.timestamp - 3_601, block.timestamp));
        script.run();
    }

    function test_run_refusesAChainOtherThanBaseSepoliaOrAnvil() public {
        vm.chainId(8_453);
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.UnsupportedChain.selector, 8_453));
        script.run();
    }

    /// @dev Writes, reads back and removes a deployment file, as the broadcast context cannot be reached from a test
    function test_writeDeployment_writesTheAddressesTheAppReads() public {
        _deploy();
        string memory path = "app/src/config/deployments/rehearsal.json";
        vm.setEnv("DEPLOYMENT_FILE", path);
        script.exposedWriteDeployment(d);
        vm.setEnv("DEPLOYMENT_FILE", "");

        string memory json = vm.readFile(path);
        vm.removeFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid, "chain id");
        assertEq(vm.parseJsonAddress(json, ".deployer"), deployer, "deployer");
        assertEq(vm.parseJsonAddress(json, ".vault"), address(d.vault), "vault");
        assertEq(vm.parseJsonAddress(json, ".tradingStorage"), address(d.tradingStorage), "storage");
        assertEq(vm.parseJsonAddress(json, ".engine"), address(d.engine), "engine");
        assertEq(vm.parseJsonAddress(json, ".spreadManager"), address(d.spreadManager), "spread manager");
        assertEq(vm.parseJsonAddress(json, ".oracle"), address(d.oracle), "oracle");
        assertEq(vm.parseJsonAddress(json, ".assistantFund"), address(d.assistantFund), "assistant fund");
        assertEq(vm.parseJsonAddress(json, ".synth"), address(d.synth), "synth");
        assertEq(vm.parseJsonAddress(json, ".bondDepository"), address(d.bondDepository), "bond depository");
        assertEq(vm.parseJsonAddress(json, ".solvencyManager"), address(d.solvencyManager), "solvency manager");
        assertEq(vm.parseJsonAddress(json, ".faucet"), address(faucet), "faucet");
        assertEq(vm.parseJsonAddress(json, ".usdc"), address(usdc), "usdc");
        assertEq(vm.parseJsonAddress(json, ".pyth"), address(pyth), "pyth");
    }

    /// @dev SeedTrades builds its updates with the scripts' helper; it must produce the app's bytes
    function test_scriptsHelper_buildsTheSameEntryAsTheApp() public {
        _deploy();
        for (uint256 i; i < 3; ++i) {
            assertEq(script.exposedMirrorPair(d.oracle, pyth, i), _entry(i, block.timestamp), "same bytes");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              SEED TRADES
    //////////////////////////////////////////////////////////////*/

    function test_seed_opensBothSidesWithMoreOnOne() public {
        _deployAndSeed();

        // collateral - 0.08% of 5x notional, times 5, at 18 decimals
        assertEq(d.tradingStorage.getOpenInterestLong(BTC), 199_200e18, "BTC long");
        assertEq(d.tradingStorage.getOpenInterestShort(BTC), 99_600e18, "BTC short");
        assertEq(d.tradingStorage.getOpenInterestLong(ETH), 49_800e18, "ETH long");
        assertEq(d.tradingStorage.getOpenInterestShort(ETH), 149_400e18, "ETH short");
        assertEq(d.tradingStorage.getOpenInterest(LINK), 0, "LINK left empty");
        assertEq(d.tradingStorage.getUserActiveTradesCount(deployer), 4, "four seed trades");
        assertFalse(d.vault.isPnlSnapshotFresh(), "deposits now need a refresh");
    }

    function test_seed_fundingFlowsFromTheHeavySide() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.engine));

        vm.warp(block.timestamp + 1 hours);
        _setPrice(btcFeed, 100_000e8);
        _open(VISITOR, BTC, false, 1_000e6, 2, btcFeed);

        assertGt(d.tradingStorage.getCumulativeFundingIndex(BTC, true), 0, "BTC longs pay");
        assertLt(d.tradingStorage.getCumulativeFundingIndex(BTC, false), 0, "BTC shorts receive");
    }

    /// @dev A rerun after a partial landing opens only what is missing
    function test_seed_rerunSkipsTheTradesAlreadyOpen() public {
        _deployAndSeed();
        SeedTrades seeder = new SeedTrades();
        seeder.seed(SeedTrades.Target({engine: d.engine, tradingStorage: d.tradingStorage, oracle: d.oracle, pyth: pyth, faucet: faucet}));
        assertEq(d.tradingStorage.getTradeCounter(), 4, "no duplicate");
    }

    /*//////////////////////////////////////////////////////////////
                              APP FLOWS
    //////////////////////////////////////////////////////////////*/

    function test_appFlow_openUpdateLevelsAndClose() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.engine));

        uint32 id = _open(VISITOR, ETH, true, 1_000e6, 10, ethFeed);
        assertEq(VISITOR.balance, 1 ether - 1, "only the update fee was kept");

        vm.warp(block.timestamp + 10);
        bytes[] memory update = _one(ETH);
        vm.prank(VISITOR);
        d.engine.updateTp{value: 1 wei}(id, 4_400e18, update);
        update = _one(ETH);
        vm.prank(VISITOR);
        d.engine.updateSl{value: 1 wei}(id, 3_700e18, update);
        TradingStorage.Trade memory trade = d.tradingStorage.getTrade(id);
        assertEq(trade.tp, 4_400e18, "tp");
        assertEq(trade.sl, 3_700e18, "sl");

        vm.warp(block.timestamp + 10);
        _setPrice(ethFeed, 4_100e8);
        update = _one(ETH);
        uint128 closeQuote = uint128((uint256(_price18(ethFeed)) * (10_000 - 5)) / 10_000);
        uint256 before = usdc.balanceOf(VISITOR);
        vm.prank(VISITOR);
        d.engine.closeTrade{value: 1 wei}(id, closeQuote, 50, update);
        assertGt(usdc.balanceOf(VISITOR), before + 1_000e6, "closed in profit");
        assertEq(VISITOR.balance, 1 ether - 4, "one wei per call that read a price");
    }

    function test_appFlow_keeperExecutesATriggeredTakeProfit() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.engine));
        uint32 id = _open(VISITOR, BTC, true, 1_000e6, 10, btcFeed);
        bytes[] memory update = _one(BTC);
        vm.prank(VISITOR);
        d.engine.updateTp{value: 1 wei}(id, 101_000e18, update);

        vm.warp(block.timestamp + 60);
        _setPrice(btcFeed, 101_500e8);
        update = _one(BTC);
        vm.deal(KEEPER, 1 ether);
        vm.prank(KEEPER);
        d.engine.executeLimit{value: 1 wei}(id, update);

        assertEq(d.tradingStorage.getTrade(id).user, address(0), "trade settled");
        // 0.1% of the 9,920 USDC notional
        assertEq(usdc.balanceOf(KEEPER), 9_920_000, "executor reward");
    }

    function test_appFlow_keeperLiquidatesAfterAMove() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.engine));
        uint32 id = _open(VISITOR, ETH, true, 1_000e6, 50, ethFeed);

        vm.warp(block.timestamp + 60);
        _setPrice(ethFeed, 3_880e8); // -3%
        bytes[] memory update = _one(ETH);
        vm.deal(KEEPER, 1 ether);
        vm.prank(KEEPER);
        d.engine.liquidate{value: 1 wei}(id, update);

        assertEq(d.tradingStorage.getTrade(id).user, address(0), "liquidated");
        assertGt(usdc.balanceOf(KEEPER), 0, "liquidator reward");
    }

    function test_appFlow_depositRequestAndExecuteAWithdrawal() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.vault));

        // A plain deposit needs a fresh snapshot, which the seed trades made stale
        vm.prank(VISITOR);
        vm.expectRevert(abi.encodeWithSelector(Vault.StalePnlSnapshot.selector, 0));
        d.vault.deposit(5_000e6, VISITOR);

        bytes[] memory update = _all();
        vm.prank(VISITOR);
        uint256 shares = d.vault.refreshAndDeposit{value: 3 wei}(5_000e6, VISITOR, update);
        assertGt(shares, 0, "shares minted");
        assertEq(VISITOR.balance, 1 ether - 3, "one wei per entry");

        vm.prank(VISITOR);
        d.vault.requestWithdrawal(shares);
        uint256 unlockAt = d.vault.DEPLOY_TIMESTAMP() + 3 days;
        vm.warp(unlockAt - 1);
        _setPrice(btcFeed, 100_000e8);
        _setPrice(ethFeed, 4_000e8);
        _setPrice(linkFeed, 20e8);
        update = _all();
        vm.prank(VISITOR);
        vm.expectRevert(abi.encodeWithSelector(Vault.WithdrawalLocked.selector, 3));
        d.vault.refreshAndExecuteWithdrawal{value: 3 wei}(update);

        vm.warp(unlockAt);
        update = _all();
        uint256 before = usdc.balanceOf(VISITOR);
        vm.prank(VISITOR);
        d.vault.refreshAndExecuteWithdrawal{value: 3 wei}(update);
        assertGt(usdc.balanceOf(VISITOR), before, "withdrawn");
    }

    /// @dev Under 95% realised the deposit path refuses, and a visitor opens the round and bonds with faucet USDC
    function test_appFlow_bondingRoundOpensAndAVisitorBonds() public {
        _deployAndSeed();

        // A large winning trade, funded by the faucet owner, takes more than 5% of the Vault
        vm.prank(deployer);
        faucet.mint(VISITOR, 100_000e6);
        vm.prank(VISITOR);
        usdc.approve(address(d.engine), type(uint256).max);
        vm.deal(VISITOR, 1 ether);
        uint32 id = _open(VISITOR, BTC, true, 100_000e6, 10, btcFeed);
        vm.warp(block.timestamp + 60);
        _setPrice(btcFeed, 106_000e8);
        bytes[] memory update = _one(BTC);
        uint128 closeQuote = uint128((uint256(_price18(btcFeed)) * 9_990) / 10_000);
        vm.prank(VISITOR);
        d.engine.closeTrade{value: 1 wei}(id, closeQuote, 50, update);
        assertLt(d.vault.realisedCollateralizationRatio(), 0.95e18, "realised ratio below 95%");

        // The deposit path refuses while a round is due
        _claimAndApprove(GRIEFER, address(d.vault));
        update = _all();
        vm.prank(GRIEFER);
        vm.expectRevert(Vault.BondingRoundOpen.selector);
        d.vault.refreshAndDeposit{value: 3 wei}(1_000e6, GRIEFER, update);

        // A visitor opens it (permissionless) and bonds
        _claimAndApprove(KEEPER, address(d.bondDepository));
        update = _all();
        vm.prank(KEEPER);
        d.solvencyManager.refreshAndCheckAndAct{value: 3 wei}(update);
        assertTrue(d.bondDepository.isActive(), "round open");

        vm.prank(KEEPER);
        (uint256 bondId, uint256 synthOut) = d.bondDepository.bond(10_000e6);
        // 10,000 USDC at 2 USDC per SYNTH less 5%
        assertEq(synthOut, uint256(10_000e6 * 1e18) / 1_900_000, "discounted SYNTH");

        vm.warp(block.timestamp + 48 hours);
        vm.prank(KEEPER);
        d.bondDepository.claim(bondId);
        assertEq(d.synth.balanceOf(KEEPER), synthOut, "fully vested");
    }

    /*//////////////////////////////////////////////////////////////
                        FAILURE MODES AND GRIEFING
    //////////////////////////////////////////////////////////////*/

    /// @dev A price chosen inside the oracle's 3% band is what DemoPyth exists to refuse
    function test_failure_aForgedPriceRevertsInDemoPyth() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.engine));

        PythStructs.PriceFeed memory feed = abi.decode(_entry(BTC, block.timestamp), (PythStructs.PriceFeed));
        feed.price.price = 97_000e8; // -3%, inside the oracle's deviation band
        feed.price.conf = uint64(97_000e8 * 5) / 10_000;
        bytes[] memory update = new bytes[](1);
        update[0] = abi.encode(feed);

        vm.prank(VISITOR);
        vm.expectRevert(abi.encodeWithSelector(DemoPyth.PriceNotChainlinkAnswer.selector, feed.id, int64(97_000e8), int256(100_000e8)));
        d.engine.openTrade{value: 1 wei}(BTC, true, 1_000e6, 100, 97_100e18, 100, 0, 0, update);
    }

    function test_failure_chainlinkMovesWhileTheVisitorSigns() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.engine));
        bytes[] memory update = _one(ETH);
        uint128 quote = _openQuote(ETH, true, ethFeed);

        _setPrice(ethFeed, 4_004e8);
        vm.prank(VISITOR);
        vm.expectRevert(
            abi.encodeWithSelector(DemoPyth.PriceNotChainlinkAnswer.selector, d.oracle.getPairFeed(ETH).pythFeedId, int64(4_000e8), int256(4_004e8))
        );
        d.engine.openTrade{value: 1 wei}(ETH, true, 1_000e6, 10, quote, 50, 0, 0, update);
    }

    /// @dev 30 s is the window between the app stamping a price and the transaction landing
    function test_failure_aPriceOlderThan30SecondsIsStale() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.engine));
        uint128 quote = _openQuote(ETH, true, ethFeed);
        bytes32 id = d.oracle.getPairFeed(ETH).pythFeedId;

        bytes[] memory update = new bytes[](1);
        update[0] = _entry(ETH, block.timestamp - 31);
        vm.prank(VISITOR);
        vm.expectRevert(abi.encodeWithSelector(PythChainlinkOracle.StalePrice.selector, id, block.timestamp - 31, block.timestamp));
        d.engine.openTrade{value: 1 wei}(ETH, true, 1_000e6, 10, quote, 50, 0, 0, update);

        update[0] = _entry(ETH, block.timestamp - 30);
        vm.prank(VISITOR);
        d.engine.openTrade{value: 1 wei}(ETH, true, 1_000e6, 10, quote, 50, 0, 0, update);
    }

    /// @dev A stranger's earlier push, even with an old publishTime, is replaced by the update the app's call carries
    function test_griefing_anEarlierPushIsOverwrittenByTheAppsUpdate() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.engine));

        bytes[] memory stale = new bytes[](1);
        stale[0] = _entry(BTC, 1);
        vm.deal(GRIEFER, 1 ether);
        vm.prank(GRIEFER);
        pyth.updatePriceFeeds{value: 1 wei}(stale);

        uint32 id = _open(VISITOR, BTC, true, 1_000e6, 10, btcFeed);
        assertEq(d.tradingStorage.getTrade(id).user, VISITOR, "the app's own update was the one read");
    }

    /// @dev Filling a pair's max OI stops new opens on it, but closes and liquidations still settle, and the owner can raise it
    function test_griefing_aFullPairStillSettlesAndTheOwnerCanRaiseIt() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.engine));
        uint32 id = _open(VISITOR, LINK, true, 1_000e6, 10, linkFeed);

        // A griefer funded far beyond the daily drip fills the rest of LINK's 5M cap exactly:
        // 103,960 USDC less the 4% open fee, at 50x, is 4,990,080 next to the visitor's 9,920
        vm.prank(deployer);
        faucet.mint(GRIEFER, 103_960e6);
        vm.prank(GRIEFER);
        usdc.approve(address(d.engine), type(uint256).max);
        vm.deal(GRIEFER, 1 ether);
        _open(GRIEFER, LINK, false, 103_960e6, 50, linkFeed);
        assertEq(d.tradingStorage.getOpenInterest(LINK), 5_000_000e18, "LINK full");

        _claimAndApprove(KEEPER, address(d.engine));
        bytes[] memory update = _one(LINK);
        uint128 quote = _openQuote(LINK, true, linkFeed);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(TradingStorage.MaxOpenInterestExceeded.selector, 5_048_000e18, 5_000_000e18));
        d.engine.openTrade{value: 1 wei}(LINK, true, 1_000e6, 50, quote, 50, 0, 0, update);

        update = _one(LINK);
        uint128 closeQuote = uint128((uint256(_price18(linkFeed)) * 9_990) / 10_000);
        vm.prank(VISITOR);
        d.engine.closeTrade{value: 1 wei}(id, closeQuote, 50, update);
        assertEq(d.tradingStorage.getTrade(id).user, address(0), "a close still settles");

        vm.prank(deployer);
        d.tradingStorage.updatePair(LINK, 50, 10_000_000e18, true);
        _open(KEEPER, LINK, true, 1_000e6, 50, linkFeed);
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The node estimates at the latest block's timestamp. When the pair's funding was updated in that same second,
     *      _updateFundingIndex is a no-op in the estimate but writes both indexes and the timestamp once the call lands a
     *      second later; from zero indexes that is two fresh slots, and the new trade's entry index is no longer zero. The
     *      app's margin, estimate * 1.25 + 50,000 (app/src/hooks/useTx.ts), must cover the difference.
     */
    function test_gas_theAppMarginCoversTheFundingAccrualWrite() public {
        _deployAndSeed();
        _claimAndApprove(VISITOR, address(d.engine));
        bytes[] memory update = _one(BTC);
        uint128 quote = _openQuote(BTC, false, btcFeed);
        uint256 snapshot = vm.snapshotState();

        // Same second as the seed trades: no accrual write
        vm.prank(VISITOR);
        uint256 gasStart = gasleft();
        d.engine.openTrade{value: 1 wei}(BTC, false, 1_000e6, 10, quote, 50, 0, 0, update);
        uint256 estimated = gasStart - gasleft();

        vm.revertToState(snapshot);
        vm.warp(block.timestamp + 1);
        update = _one(BTC);
        vm.prank(VISITOR);
        gasStart = gasleft();
        d.engine.openTrade{value: 1 wei}(BTC, false, 1_000e6, 10, quote, 50, 0, 0, update);
        uint256 landed = gasStart - gasleft();

        emit log_named_uint("openTrade gas, same second as the last accrual", estimated);
        emit log_named_uint("openTrade gas, one second later", landed);
        assertGt(landed, estimated, "the accrual write costs more");
        assertLe(landed, (estimated * 125) / 100 + 50_000, "within the app's margin");
    }
}
