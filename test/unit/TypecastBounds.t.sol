// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {Vault} from "../../src/Vault.sol";
import {BondDepository} from "../../src/BondDepository.sol";
import {SynthToken} from "../../src/SynthToken.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpreadManager} from "../mocks/MockSpreadManager.sol";
import {MockSolvencyVault} from "../mocks/MockSolvencyVault.sol";
import {RegressionUSDC} from "../regression/RegressionBase.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/**
 * @title TypecastBoundsTest
 * @author GushALKDev
 * @notice The downcasts that use SafeCastLib, at their bound: the largest input fits, the next one reverts with
 *         SafeCastLib.Overflow instead of truncating. The per-side quantity bound is in TradingStorage.t.sol
 *         (test_StoreTrade_QuantityAtUint128Bound).
 */
contract TypecastBoundsTest is Test {
    address owner = makeAddr("owner");
    bytes32 constant FEED_ID = bytes32(uint256(1));
    bytes[] EMPTY;

    function setUp() public {
        vm.warp(1_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                  ORACLE: NORMALIZED PRICE TO UINT128
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev A feed with a positive exponent: price * 10^(18 + expo) can pass 2^128 (about 3.4e38). 3e18 at expo +2 is
     *      3e38 and fits; 4e18 is 4e38 and does not. Chainlink agrees, so only the cast can reject it.
     */
    function _oracleAt(int64 _price) internal returns (PythChainlinkOracle oracle, bytes[] memory data) {
        MockPyth mockPyth = new MockPyth(60, 0);
        MockChainlinkFeed feed = new MockChainlinkFeed(8);
        feed.setAnswer(int256(_price) * 1e10); // 8 decimals: price * 10^(2 + 8)
        vm.startPrank(owner);
        oracle = new PythChainlinkOracle(address(mockPyth), address(0), owner);
        oracle.setPairFeed(0, FEED_ID, address(feed), 3600);
        vm.stopPrank();
        data = new bytes[](1);
        data[0] = mockPyth.createPriceFeedUpdateData(FEED_ID, _price, uint64(_price / 100), 2, _price, 0, uint64(block.timestamp), uint64(block.timestamp - 1));
    }

    function test_Oracle_NormalizedPriceFitsAtBound() public {
        (PythChainlinkOracle oracle, bytes[] memory data) = _oracleAt(3e18);
        (uint128 price,) = oracle.getPrice(0, data);
        assertEq(price, 3e38);
    }

    function test_Oracle_NormalizedPriceAboveUint128Reverts() public {
        (PythChainlinkOracle oracle, bytes[] memory data) = _oracleAt(4e18);
        vm.expectRevert(SafeCastLib.Overflow.selector);
        oracle.getPrice(0, data);
    }

    /*//////////////////////////////////////////////////////////////
               ENGINE: PRICE WITH THE SPREAD ADDED
    //////////////////////////////////////////////////////////////*/

    function _engineAt(uint128 _price) internal returns (TradingEngine engine) {
        RegressionUSDC usdc = new RegressionUSDC();
        MockOracle mockOracle = new MockOracle();
        mockOracle.setPrice(0, _price);
        vm.startPrank(owner);
        TradingStorage tradingStorage = new TradingStorage(address(usdc), owner);
        Vault vault = new Vault(address(usdc), owner, address(tradingStorage), address(mockOracle));
        engine = new TradingEngine(
            address(tradingStorage), address(vault), address(mockOracle), address(usdc), makeAddr("treasury"), address(new MockSpreadManager(5)), owner
        );
        tradingStorage.setTradingEngine(address(engine));
        vault.setTradingEngine(address(engine));
        tradingStorage.addPair("BIG/USD", 100, type(uint128).max);
        vm.stopPrank();
        usdc.mint(address(this), 100 * 10 ** 6);
        usdc.approve(address(engine), type(uint256).max);
    }

    /// @notice At the largest oracle price the 5 BPS open spread keeps within uint128, a long opens
    function test_Engine_SpreadPriceFitsAtBound() public {
        uint128 price = uint128((uint256(type(uint128).max) * 10_000) / 10_005);
        TradingEngine engine = _engineAt(price);
        uint128 expected = uint128((uint256(price) * 10_005) / 10_000);
        engine.openTrade(0, true, 100 * 10 ** 6, 1, expected, 0, 0, 0, EMPTY);
    }

    /// @notice One step above, the price with the spread passes 2^128 and the open reverts
    function test_Engine_SpreadPriceAboveUint128Reverts() public {
        TradingEngine engine = _engineAt(type(uint128).max);
        vm.expectRevert(SafeCastLib.Overflow.selector);
        engine.openTrade(0, true, 100 * 10 ** 6, 1, type(uint128).max, 0, 0, 0, EMPTY);
    }

    /*//////////////////////////////////////////////////////////////
                BOND: $SYNTH OUT TO UINT128
    //////////////////////////////////////////////////////////////*/

    /// @dev Effective price 1 (reference 1, no discount), round cap and deficit above the bound
    function _bondAtPriceOne() internal returns (BondDepository bond, RegressionUSDC usdc) {
        usdc = new RegressionUSDC();
        MockSolvencyVault mockVault = new MockSolvencyVault();
        vm.startPrank(owner);
        SynthToken synth = new SynthToken(owner);
        bond = new BondDepository(address(usdc), address(mockVault), address(synth), 0, owner);
        synth.setMinter(address(bond));
        bond.setReferencePrice(1);
        bond.setSolvencyManager(owner);
        bond.activateBonding(type(uint128).max);
        vm.stopPrank();
        usdc.mint(address(this), type(uint128).max);
        usdc.approve(address(bond), type(uint256).max);
    }

    /// @notice The largest bond whose $SYNTH fits uint128 goes through
    function test_Bond_SynthOutFitsAtBound() public {
        (BondDepository bond,) = _bondAtPriceOne();
        uint256 usdcIn = type(uint128).max / 1e18;
        (, uint256 synthOut) = bond.bond(usdcIn);
        assertEq(synthOut, usdcIn * 1e18);
    }

    function test_Bond_SynthOutAboveUint128Reverts() public {
        (BondDepository bond,) = _bondAtPriceOne();
        uint256 usdcIn = type(uint128).max / 1e18 + 1;
        vm.expectRevert(SafeCastLib.Overflow.selector);
        bond.bond(usdcIn);
    }

    /*//////////////////////////////////////////////////////////////
                  VAULT: SNAPSHOT NET PNL TO INT128
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev One long of 340.282366 USDC at 1x opened at 1 wei: quantity 3.40282366e38. Its PnL in USDC passes
     *      type(int128).max (about 1.7e38) once the price exceeds about 5e29 (5e11 USD per unit).
     */
    function _vaultWithHugeQuantity(uint128 _price) internal returns (Vault vault) {
        RegressionUSDC usdc = new RegressionUSDC();
        MockOracle mockOracle = new MockOracle();
        address engineAddr = makeAddr("engine");
        vm.startPrank(owner);
        TradingStorage tradingStorage = new TradingStorage(address(usdc), owner);
        vault = new Vault(address(usdc), owner, address(tradingStorage), address(mockOracle));
        tradingStorage.setTradingEngine(engineAddr);
        tradingStorage.addPair("TINY/USD", 100, type(uint128).max);
        vm.stopPrank();
        vm.startPrank(engineAddr);
        tradingStorage.storeTrade(owner, true, 0, 1, 340_282_366, 1, 0, 0);
        tradingStorage.increaseOpenInterest(0, 340_282_366 * 1e12, true);
        vm.stopPrank();
        mockOracle.setPrice(0, _price);
    }

    function test_Vault_SnapshotFitsInt128BelowBound() public {
        Vault vault = _vaultWithHugeQuantity(1e29);
        vault.refreshPnlSnapshot(EMPTY);
        (int128 netPnl,,) = vault.pnlSnapshot();
        assertGt(netPnl, 0);
    }

    function test_Vault_SnapshotAboveInt128Reverts() public {
        Vault vault = _vaultWithHugeQuantity(1e30);
        vm.expectRevert(SafeCastLib.Overflow.selector);
        vault.refreshPnlSnapshot(EMPTY);
    }
}
