// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SolvencyManager} from "../../src/SolvencyManager.sol";

contract MockVault {
    uint256 public totalAssets;
    uint256 public collateralizationRatio;

    function setState(uint256 _totalAssets, uint256 _cr) external {
        totalAssets = _totalAssets;
        collateralizationRatio = _cr;
    }
}

contract MockAssistantFund {
    uint256 public balance;
    uint256 public lastInjected;
    uint256 public totalInjected;

    function setBalance(uint256 _balance) external {
        balance = _balance;
    }

    function injectFunds(uint256 amount) external {
        require(amount <= balance, "insufficient");
        balance -= amount;
        lastInjected = amount;
        totalInjected += amount;
    }
}

contract MockBondDepository {
    bool public isActive;
    uint256 public lastNeeded;

    function setActive(bool _active) external {
        isActive = _active;
    }

    function activateBonding(uint256 neededUsdc) external {
        isActive = true;
        lastNeeded = neededUsdc;
    }
}

contract SolvencyManagerTest is Test {
    SolvencyManager manager;
    MockVault vault;
    MockAssistantFund fund;
    MockBondDepository bondDepo;

    address owner = makeAddr("owner");

    uint256 constant WAD = 1e18;

    event Healthy(uint256 cr);
    event Warning(uint256 cr);
    event ReserveInjected(uint256 cr, uint256 amount);
    event BondingTriggered(uint256 cr, uint256 neededUsdc);

    function setUp() public {
        vault = new MockVault();
        fund = new MockAssistantFund();
        bondDepo = new MockBondDepository();
        manager = new SolvencyManager(address(vault), address(fund), address(bondDepo), owner);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_State() public view {
        assertEq(address(manager.VAULT()), address(vault));
        assertEq(address(manager.ASSISTANT_FUND()), address(fund));
        assertEq(address(manager.BOND_DEPOSITORY()), address(bondDepo));
        assertEq(manager.owner(), owner);
        assertEq(manager.SAFE_CR(), 110e16);
        assertEq(manager.DEFICIT_CR(), 100e16);
        assertEq(manager.CRITICAL_CR(), 95e16);
    }

    function test_Constructor_ZeroAddressReverts() public {
        vm.expectRevert(SolvencyManager.ZeroAddress.selector);
        new SolvencyManager(address(0), address(fund), address(bondDepo), owner);
        vm.expectRevert(SolvencyManager.ZeroAddress.selector);
        new SolvencyManager(address(vault), address(0), address(bondDepo), owner);
        vm.expectRevert(SolvencyManager.ZeroAddress.selector);
        new SolvencyManager(address(vault), address(fund), address(0), owner);
    }

    /*//////////////////////////////////////////////////////////////
                        CHECK AND ACT - HEALTHY
    //////////////////////////////////////////////////////////////*/

    function test_CheckAndAct_HealthyNoAction() public {
        vault.setState(1_100_000 * 10 ** 6, 111e16); // CR 111% > SAFE
        fund.setBalance(500_000 * 10 ** 6);

        vm.expectEmit(false, false, false, true);
        emit Healthy(111e16);
        manager.checkAndAct();

        assertEq(fund.totalInjected(), 0);
        assertFalse(bondDepo.isActive());
    }

    function test_CheckAndAct_WarningNoAction() public {
        vault.setState(1_050_000 * 10 ** 6, 105e16); // 100% <= CR < 110%
        fund.setBalance(500_000 * 10 ** 6);

        vm.expectEmit(false, false, false, true);
        emit Warning(105e16);
        manager.checkAndAct();

        assertEq(fund.totalInjected(), 0);
        assertFalse(bondDepo.isActive());
    }

    /*//////////////////////////////////////////////////////////////
                    CHECK AND ACT - RESERVE INJECTION
    //////////////////////////////////////////////////////////////*/

    function test_CheckAndAct_InjectsFromReserve() public {
        // CR 97% (deficit zone, not critical). totalAssets = 970k → deficit to 100%
        // deficit = 970000e6 * (1e18 - 0.97e18) / 0.97e18 = 970000e6 * 3/97 = 30000e6
        vault.setState(970_000 * 10 ** 6, 97e16);
        fund.setBalance(500_000 * 10 ** 6); // plenty

        uint256 expectedDeficit = (uint256(970_000 * 10 ** 6) * (100e16 - 97e16)) / 97e16;

        vm.expectEmit(false, false, false, true);
        emit ReserveInjected(97e16, expectedDeficit);
        manager.checkAndAct();

        assertEq(fund.lastInjected(), expectedDeficit);
        assertFalse(bondDepo.isActive()); // not critical → no bonding
    }

    function test_CheckAndAct_PartialReserveNoBondingIfNotCritical() public {
        // CR 97% (not critical) but reserve smaller than deficit → inject all, no bonding
        vault.setState(970_000 * 10 ** 6, 97e16);
        fund.setBalance(10_000 * 10 ** 6);

        manager.checkAndAct();

        assertEq(fund.totalInjected(), 10_000 * 10 ** 6);
        assertEq(fund.balance(), 0);
        assertFalse(bondDepo.isActive()); // above CRITICAL_CR, no bonding despite shortfall
    }

    /*//////////////////////////////////////////////////////////////
                    CHECK AND ACT - BONDING
    //////////////////////////////////////////////////////////////*/

    function test_CheckAndAct_CriticalActivatesBondingForShortfall() public {
        // CR 90% (critical). deficit = 900000e6 * (1e18-0.9e18)/0.9e18 = 900000e6 * 10/90 = 100000e6
        vault.setState(900_000 * 10 ** 6, 90e16);
        fund.setBalance(40_000 * 10 ** 6); // reserve covers only part

        uint256 deficit = (uint256(900_000 * 10 ** 6) * (100e16 - 90e16)) / 90e16;
        uint256 shortfall = deficit - 40_000 * 10 ** 6;

        vm.expectEmit(false, false, false, true);
        emit ReserveInjected(90e16, 40_000 * 10 ** 6);
        vm.expectEmit(false, false, false, true);
        emit BondingTriggered(90e16, shortfall);
        manager.checkAndAct();

        assertEq(fund.totalInjected(), 40_000 * 10 ** 6);
        assertTrue(bondDepo.isActive());
        assertEq(bondDepo.lastNeeded(), shortfall);
    }

    function test_CheckAndAct_CriticalEmptyReserveBondsFullDeficit() public {
        vault.setState(900_000 * 10 ** 6, 90e16);
        fund.setBalance(0);

        uint256 deficit = (uint256(900_000 * 10 ** 6) * (100e16 - 90e16)) / 90e16;

        manager.checkAndAct();

        assertEq(fund.totalInjected(), 0);
        assertTrue(bondDepo.isActive());
        assertEq(bondDepo.lastNeeded(), deficit);
    }

    function test_CheckAndAct_CriticalReserveCoversAllNoBonding() public {
        vault.setState(900_000 * 10 ** 6, 90e16);
        fund.setBalance(1_000_000 * 10 ** 6); // covers full deficit

        uint256 deficit = (uint256(900_000 * 10 ** 6) * (100e16 - 90e16)) / 90e16;

        manager.checkAndAct();

        assertEq(fund.totalInjected(), deficit);
        assertFalse(bondDepo.isActive()); // no shortfall left
    }

    function test_CheckAndAct_DoesNotReactivateBonding() public {
        vault.setState(900_000 * 10 ** 6, 90e16);
        fund.setBalance(0);
        bondDepo.setActive(true); // a round is already running

        manager.checkAndAct();

        assertEq(bondDepo.lastNeeded(), 0); // activateBonding not called
    }

    /*//////////////////////////////////////////////////////////////
                            DEFICIT VIEW
    //////////////////////////////////////////////////////////////*/

    function test_DeficitToTarget_ZeroWhenHealthy() public {
        vault.setState(1_100_000 * 10 ** 6, 110e16);
        assertEq(manager.deficitToTarget(), 0);
    }

    function test_DeficitToTarget_Value() public {
        vault.setState(970_000 * 10 ** 6, 97e16);
        uint256 expected = (uint256(970_000 * 10 ** 6) * (100e16 - 97e16)) / 97e16;
        assertEq(manager.deficitToTarget(), expected);
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DeficitRestoresToHundred(uint256 totalAssets, uint256 cr) public {
        totalAssets = bound(totalAssets, 1 * 10 ** 6, 100_000_000 * 10 ** 6);
        cr = bound(cr, 1e16, 99e16); // 1% .. 99%

        vault.setState(totalAssets, cr);
        uint256 deficit = manager.deficitToTarget();

        // After injecting `deficit`, new totalAssets should reach ~100% nominal liabilities.
        // nominalLiab = totalAssets * WAD / cr; check (totalAssets + deficit) ~= nominalLiab
        uint256 nominalLiab = (totalAssets * WAD) / cr;
        // Allow rounding slack of a few wei from integer division
        assertApproxEqAbs(totalAssets + deficit, nominalLiab, 2);
    }
}
