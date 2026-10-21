// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/console.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {Deploy, DeployLib, Deployed} from "../Deploy.s.sol";
import {DemoPyth} from "./DemoPyth.sol";
import {TestnetFaucet} from "./TestnetFaucet.sol";
import {TestnetPrices} from "./TestnetPrices.sol";

/**
 * @title DeployTestnet
 * @author GushALKDev
 * @notice Public testnet deployment of the demo (Base Sepolia by default; a local anvil chain for the app's tests):
 *         the full protocol from DeployLib with the parameters of Deploy.s.sol, three pairs, a USDC faucet, DemoPyth
 *         in place of Pyth, the real Chainlink feeds of the chain as anchors, and the seed liquidity.
 * @dev What differs from a production deployment, and why:
 *      - USDC: TestnetFaucet deploys a 6-decimal stand-in, so the Vault can be seeded and visitors can claim some.
 *      - Pyth: DemoPyth, because Hermes needs an API key. The app mirrors the Chainlink answer into it in every
 *        price-dependent call, and DemoPyth rejects any other price (see DemoPyth for what it does and does not check).
 *      - Sequencer uptime feed: address(0). Chainlink lists none for Base Sepolia, so the oracle's sequencer and
 *        grace period checks are off on this deployment.
 *      - Pyth price age: oracle.setMaxPriceAge(MAX_PRICE_AGE), the oracle's own ceiling, up from its 5 s default: the
 *        app stamps each price with the latest block's timestamp before the visitor signs, and a wallet signature
 *        takes longer than 5 s.
 *      - Anchor heartbeat: the Base Sepolia BTC, ETH and LINK feeds update at least every 1,200 s; ANCHOR_HEARTBEAT
 *        adds a margin, so an update that lands a few seconds late does not make the anchor read as stale.
 *      - Liquidity: the deployer deposits SEED_LIQUIDITY USDC with the faucet contract as receiver. The faucet has no
 *        function to request a withdrawal, so that liquidity stays in the Vault.
 *      The run ends, in simulation only, by mirroring every pair's Chainlink answer into DemoPyth and reading each
 *      price through the oracle's full pipeline: a stale or missing anchor reverts the run before anything is sent.
 *      On a broadcast it also writes the deployment file the app reads. SeedTrades.s.sol then opens the seed trades,
 *      as a separate run because each one carries a price that must be at most MAX_PRICE_AGE old when it lands.
 *
 *      Usage (Base Sepolia):
 *        forge script script/testnet/DeployTestnet.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --account <keystore> --broadcast
 *      Optional env: BTC_CL_FEED, ETH_CL_FEED, LINK_CL_FEED (required on anvil), DEPLOYMENT_FILE.
 */
contract DeployTestnet is Deploy, TestnetPrices {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 internal constant ANVIL_CHAIN_ID = 31_337;

    /// @dev Chainlink feeds on Base Sepolia (Chainlink data feed directory, checked 21 Oct 2026)
    address internal constant BASE_SEPOLIA_BTC_USD = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    address internal constant BASE_SEPOLIA_ETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address internal constant BASE_SEPOLIA_LINK_USD = 0xb113F5A928BCfF189C998ab20d753a47F9dE5A61;

    /// @dev Anchor staleness window: the feeds' 1,200 s heartbeat plus margin
    uint32 internal constant ANCHOR_HEARTBEAT = 3_600;

    /// @dev Oracle Pyth price age, the oracle's MAX_STALENESS ceiling
    uint256 internal constant MAX_PRICE_AGE = 30;

    /// @dev DemoPyth fee per update entry
    uint256 internal constant DEMO_UPDATE_FEE = 1 wei;

    /// @dev USDC deposited into the Vault on behalf of the faucet contract
    uint256 internal constant SEED_LIQUIDITY = 1_000_000e6;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice One pair of the demo, with its feeds and risk limits
    struct PairSpec {
        string name;
        bytes32 pythFeedId;
        address chainlinkFeed;
        uint16 maxLeverage;
        uint128 maxOI; // 18 decimals
    }

    /// @notice Everything the testnet run deploys besides the protocol contracts run() returns
    struct TestnetDeployment {
        TestnetFaucet faucet;
        DemoPyth pyth;
        address deployer;
        uint256 deployBlock;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The extra contracts of the last run, for tests and the deployment file
    TestnetDeployment public deployment;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnsupportedChain(uint256 chainId);

    /*//////////////////////////////////////////////////////////////
                                  RUN
    //////////////////////////////////////////////////////////////*/

    function run() external override returns (Deployed memory d) {
        // The stand-ins have no place on a chain with real value
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID && block.chainid != ANVIL_CHAIN_ID) revert UnsupportedChain(block.chainid);
        PairSpec[3] memory pairs = _pairs();
        uint256 deployBlock = block.number;

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        TestnetFaucet faucet = new TestnetFaucet(deployer);
        DemoPyth pyth = new DemoPyth(DEMO_UPDATE_FEE, deployer);

        // Same parameters as Deploy.s.sol; owner and keeper are the deployer, so the run can wire and configure
        d = DeployLib.deploy(_deployConfig(address(faucet.USDC()), address(pyth), address(0), deployer, deployer));
        DeployLib.wire(d);
        d.oracle.setMaxPriceAge(MAX_PRICE_AGE);

        for (uint256 i; i < pairs.length; ++i) {
            uint256 pairIndex = d.tradingStorage.addPair(pairs[i].name, pairs[i].maxLeverage, pairs[i].maxOI);
            d.oracle.setPairFeed(pairIndex, pairs[i].pythFeedId, pairs[i].chainlinkFeed, ANCHOR_HEARTBEAT);
            pyth.setChainlinkFeed(pairs[i].pythFeedId, pairs[i].chainlinkFeed);
        }

        // No trade is open yet, so the snapshot counts as fresh and the deposit needs no price
        faucet.mint(deployer, SEED_LIQUIDITY);
        faucet.USDC().approve(address(d.vault), SEED_LIQUIDITY);
        d.vault.deposit(SEED_LIQUIDITY, address(faucet));

        vm.stopBroadcast();

        deployment = TestnetDeployment({faucet: faucet, pyth: pyth, deployer: deployer, deployBlock: deployBlock});

        _smokeTest(d, pyth);

        // Only on a real broadcast: a dry run must not overwrite the file with addresses never deployed
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) _writeDeployment(d);

        console.log("Vault    :", address(d.vault));
        console.log("Engine   :", address(d.engine));
        console.log("Faucet   :", address(faucet));
        console.log("DemoPyth :", address(pyth));
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The three demo pairs. Base Sepolia feeds by default; any other chain must export all three.
     *      maxOI is generous on purpose: twenty faucet claims at 100x fill 20M, and updatePair can raise it.
     */
    function _pairs() internal view returns (PairSpec[3] memory pairs) {
        bool baseSepolia = block.chainid == BASE_SEPOLIA_CHAIN_ID;
        pairs[0] = PairSpec({
            name: "BTC/USD",
            pythFeedId: BTC_USD_FEED_ID,
            chainlinkFeed: baseSepolia ? vm.envOr("BTC_CL_FEED", BASE_SEPOLIA_BTC_USD) : vm.envAddress("BTC_CL_FEED"),
            maxLeverage: 100,
            maxOI: 20_000_000e18
        });
        pairs[1] = PairSpec({
            name: "ETH/USD",
            pythFeedId: ETH_USD_FEED_ID,
            chainlinkFeed: baseSepolia ? vm.envOr("ETH_CL_FEED", BASE_SEPOLIA_ETH_USD) : vm.envAddress("ETH_CL_FEED"),
            maxLeverage: 100,
            maxOI: 20_000_000e18
        });
        pairs[2] = PairSpec({
            name: "LINK/USD",
            pythFeedId: LINK_USD_FEED_ID,
            chainlinkFeed: baseSepolia ? vm.envOr("LINK_CL_FEED", BASE_SEPOLIA_LINK_USD) : vm.envAddress("LINK_CL_FEED"),
            maxLeverage: 50,
            maxOI: 5_000_000e18
        });
    }

    /**
     * @dev Simulation only, after stopBroadcast: mirrors each pair's Chainlink answer into DemoPyth the way the app
     *      does, inside the oracle call that reads it, and runs the oracle's full validation pipeline.
     */
    function _smokeTest(Deployed memory _d, DemoPyth _pyth) internal {
        // A throwaway sender: forge rejects scripts that rely on their own ephemeral address
        address smoke = makeAddr("DeployTestnet smoke test");
        uint256 pairsCount = _d.tradingStorage.getPairsCount();
        for (uint256 i; i < pairsCount; ++i) {
            bytes[] memory update = new bytes[](1);
            update[0] = _mirrorPair(_d.oracle, _pyth, i);
            uint256 fee = _pyth.getUpdateFee(update);
            vm.deal(smoke, fee);
            vm.prank(smoke);
            _d.oracle.getPrice{value: fee}(i, update);
        }
    }

    /**
     * @dev Writes the addresses the app needs to app/src/config/deployments/<chainId>.json (or DEPLOYMENT_FILE).
     *      Pair names, feeds and limits are not copied: the app reads them from TradingStorage and the oracle.
     */
    function _writeDeployment(Deployed memory _d) internal {
        TestnetDeployment memory t = deployment;
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployBlock", t.deployBlock);
        vm.serializeAddress(root, "deployer", t.deployer);
        vm.serializeAddress(root, "vault", address(_d.vault));
        vm.serializeAddress(root, "tradingStorage", address(_d.tradingStorage));
        vm.serializeAddress(root, "engine", address(_d.engine));
        vm.serializeAddress(root, "spreadManager", address(_d.spreadManager));
        vm.serializeAddress(root, "oracle", address(_d.oracle));
        vm.serializeAddress(root, "assistantFund", address(_d.assistantFund));
        vm.serializeAddress(root, "synth", address(_d.synth));
        vm.serializeAddress(root, "bondDepository", address(_d.bondDepository));
        vm.serializeAddress(root, "solvencyManager", address(_d.solvencyManager));
        vm.serializeAddress(root, "faucet", address(t.faucet));
        vm.serializeAddress(root, "usdc", address(t.faucet.USDC()));
        root = vm.serializeAddress(root, "pyth", address(t.pyth));
        vm.writeJson(root, deploymentFile());
    }

    /**
     * @notice Where the deployment file lives: DEPLOYMENT_FILE, or the app's file for this chain id
     */
    function deploymentFile() public view returns (string memory) {
        string memory defaultPath = string.concat("app/src/config/deployments/", vm.toString(block.chainid), ".json");
        return vm.envOr("DEPLOYMENT_FILE", defaultPath);
    }
}
