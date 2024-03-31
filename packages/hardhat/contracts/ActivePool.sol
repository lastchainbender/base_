// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import './Interfaces/IActivePool.sol';
import "./Interfaces/IWhitelist.sol";
import './Interfaces/IERC20.sol';
import "./Interfaces/IWAsset.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/PoolBase2.sol";
import "./Dependencies/SafeERC20.sol";

import "./Interfaces/IDefaultPool.sol";

/*
 * The Active Pool holds the all collateral and CUSD debt (but not CUSD tokens) for all active troves.
 *
 * When a trove is liquidated, its collateral and CUSD debt are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract ActivePool is OwnableUpgradeable, CheckContract, IActivePool, PoolBase2 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 constant public NAME = "ActivePool";

    address internal borrowerOperationsAddress;
    address internal troveManagerAddress;
    address internal stabilityPoolAddress;
    address internal defaultPoolAddress;
    address internal troveManagerLiquidationsAddress;
    address internal troveManagerRedemptionsAddress;
    address internal collSurplusPoolAddress;

    
    // deposited collateral tracker. Colls is always the whitelist list of all collateral tokens. Amounts 
    newColls internal poolColl;

    // CUSD Debt tracker. Tracker of all debt in the system.
    uint256 internal CUSDDebt;

    // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolCUSDDebtUpdated(uint _CUSDDebt);
    event ActivePoolBalanceUpdated(address _collateral, uint _amount);
    event ActivePoolBalancesUpdated(address[] _collaterals, uint256[] _amounts);
    event CollateralsSent(address[] _collaterals, uint256[] _amounts, address _to);

    // --- Contract setters ---

    function setUp() external {
		__Ownable_init();
	}

    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _defaultPoolAddress,
        address _whitelistAddress,
        address _troveManagerLiquidationsAddress,
        address _troveManagerRedemptionsAddress,
        address _collSurplusPoolAddress
    )
        external
        onlyOwner
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_whitelistAddress);
        checkContract(_troveManagerLiquidationsAddress);
        checkContract(_troveManagerRedemptionsAddress);
        checkContract(_collSurplusPoolAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        stabilityPoolAddress = _stabilityPoolAddress;
        defaultPoolAddress = _defaultPoolAddress;
        whitelist = IWhitelist(_whitelistAddress);
        troveManagerLiquidationsAddress = _troveManagerLiquidationsAddress;
        troveManagerRedemptionsAddress = _troveManagerRedemptionsAddress;
        collSurplusPoolAddress = _collSurplusPoolAddress;

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
        emit WhitelistAddressChanged(_whitelistAddress);

        renounceOwnership();
    }

    // --- Internal Functions ---

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the amount of a given collateral in state. Not necessarily the contract's actual balance.
    */
    function getCollateral(address _collateral) public view override returns (uint) {
        return poolColl.amounts[whitelist.getIndex(_collateral)];
    }

    /*
    * Returns all collateral balances in state. Not necessarily the contract's actual balances.
    */
    function getAllCollateral() public view override returns (address[] memory, uint256[] memory) {
        return (poolColl.tokens, poolColl.amounts);
    }

    // returns the VC value of a given collateralAddress in this contract
    function getCollateralVC(address _collateral) external view override returns (uint) {
        return whitelist.getValueVC(_collateral, getCollateral(_collateral));
    }


    /*
    * Returns the VC of the contract
    *
    * Not necessarily equal to the the contract's raw VC balance - Collateral can be forcibly sent to contracts.
    *
    * Computed when called by taking the collateral balances and
    * multiplying them by the corresponding price and ratio and then summing that
    */
    function getVC() external view override returns (uint256 totalVC) {
        uint len = poolColl.tokens.length;
        for (uint256 i; i < len; ++i) {
            uint amount = poolColl.amounts[i];

            totalVC = totalVC.add(whitelist.getValueVC(poolColl.tokens[i], amount));
        }
    }

    // Function for aggregating active pool and default pool amounts when looping through.
    function getVCSystem() external view override returns (uint256 totalVCSystem) {
        uint len = poolColl.tokens.length;
        uint256[] memory defaultPoolAmounts = IDefaultPool(defaultPoolAddress).getAllAmounts();
        for (uint256 i; i < len; ++i) {
            uint amount = poolColl.amounts[i].add(defaultPoolAmounts[i]);

            totalVCSystem = totalVCSystem.add(whitelist.getValueVC(poolColl.tokens[i], amount));
        }
    }

    // Function for getting the VC value but using the Recovery ratio instead of the safety ratio
    function getVCforTCR() external view override returns (uint256 totalVC, uint256 totalVCforTCR) {
        uint len = poolColl.tokens.length;
        for (uint256 i; i < len; ++i) {
            uint amount = poolColl.amounts[i];

            (uint256 VC, uint256 VCforTCR) = whitelist.getValueVCforTCR(poolColl.tokens[i], amount);
            totalVC = totalVC.add(VC);
            totalVCforTCR = totalVCforTCR.add(VCforTCR);
        }
    }

    // Function for getting the VC value but using the Recovery ratio instead of the safety ratio
    // Aggregates active pool and default pool amounts in one function loop. 
    function getVCforTCRSystem() external view override returns (uint256 totalVC, uint256 totalVCforTCR) {
        uint len = poolColl.tokens.length;
        uint256[] memory defaultPoolAmounts = IDefaultPool(defaultPoolAddress).getAllAmounts();
        for (uint256 i; i < len; ++i) {
            uint amount = poolColl.amounts[i].add(defaultPoolAmounts[i]);

            (uint256 VC, uint256 VCforTCR) = whitelist.getValueVCforTCR(poolColl.tokens[i], amount);
            totalVC = totalVC.add(VC);
            totalVCforTCR = totalVCforTCR.add(VCforTCR);
        }
    }


    // Debt that this pool holds. 
    function getCUSDDebt() external view override returns (uint) {
        return CUSDDebt;
    }

    // --- Pool functionality ---

    // Internal function to send collateral to a different pool. 
    function _sendCollateral(address _to, address _collateral, uint _amount) internal {
        uint index = whitelist.getIndex(_collateral);
        poolColl.amounts[index] = poolColl.amounts[index].sub(_amount);
        IERC20(_collateral).safeTransfer(_to, _amount);

        emit ActivePoolBalanceUpdated(_collateral, _amount);
        emit CollateralSent(_collateral, _to, _amount);
    }

    // Function sends collaterals from active pool.
    // Must be called by borrower operations, trove manager, or stability pool.
    function sendCollaterals(address _to, address[] calldata _tokens, uint[] calldata _amounts) external override {
        _requireCallerIsBOorTroveMorTMLorSP();
        uint256 len = _tokens.length;
        require(len == _amounts.length, "AP:Lengths");
        for (uint256 i; i < len; ++i) {
            uint256 thisAmount = _amounts[i];
            if (thisAmount != 0) {
                _sendCollateral(_to, _tokens[i], thisAmount); // reverts if send fails
            }
        }

        if (_needsUpdateCollateral(_to)) {
            ICollateralReceiver(_to).receiveCollateral(_tokens, _amounts);
        }

        emit CollateralsSent(_tokens, _amounts, _to);
    }

    // Returns true if all payments were successfully sent. Must be called by borrower operations, trove manager, or stability pool.
    // This function als ounwraps the collaterals and sends them to _to, if they are wrapped assets. If collect rewards is set to true,
    // It also harvests rewards on the user's behalf. 
    // _from is where the reward balance is, _to is where to send the tokens. 
    function sendCollateralsUnwrap(address _from, address _to, address[] calldata _tokens, uint[] calldata _amounts) external override {
        _requireCallerIsBOorTroveMorTMLorSP();
        uint256 tokensLen = _tokens.length;
        require(tokensLen == _amounts.length, "AP:Lengths");
        for (uint256 i; i < tokensLen; ++i) {
            if (whitelist.isWrapped(_tokens[i])) {
                // Collects rewards automatically for that amount and unwraps for the original borrower. 
                IWAsset(_tokens[i]).unwrapFor(_from, _to, _amounts[i]);
            } else {
                _sendCollateral(_to, _tokens[i], _amounts[i]); // reverts if send fails
            }
        }
    }

    // Function for sending single collateral. Currently only used by borrower operations unlever up functionality
    function sendSingleCollateral(address _to, address _token, uint256 _amount) external override {
        _requireCallerIsBorrowerOperations();
        _sendCollateral(_to, _token, _amount); // reverts if send fails
    }

    // Function for sending single collateral and unwrapping. Currently only used by borrower operations unlever up functionality
    function sendSingleCollateralUnwrap(address _from, address _to, address _token, uint256 _amount) external override {
        _requireCallerIsBorrowerOperations();
        if (whitelist.isWrapped(_token)) {
            // Collects rewards automatically for that amount and unwraps for the original borrower. 
            IWAsset(_token).unwrapFor(_from, _to, _amount);
        } else {
            _sendCollateral(_to, _token, _amount); // reverts if send fails
        }
    }

    // View function that returns if the contract transferring to needs to have its balances updated. 
    function _needsUpdateCollateral(address _contractAddress) internal view returns (bool) {
        return ((_contractAddress == defaultPoolAddress) || (_contractAddress == stabilityPoolAddress) || (_contractAddress == collSurplusPoolAddress));
    }

    // Increases the CUSD Debt of this pool.
    function increaseCUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveM();
        CUSDDebt  = CUSDDebt.add(_amount);
        emit ActivePoolCUSDDebtUpdated(CUSDDebt);
    }

    // Decreases the CUSD Debt of this pool.
    function decreaseCUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveMorSP();
        CUSDDebt = CUSDDebt.sub(_amount);
        emit ActivePoolCUSDDebtUpdated(CUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsBOorTroveMorTMLorSP() internal view {
        if (
            msg.sender != borrowerOperationsAddress &&
            msg.sender != troveManagerAddress &&
            msg.sender != stabilityPoolAddress &&
            msg.sender != troveManagerLiquidationsAddress &&
            msg.sender != troveManagerRedemptionsAddress) {
                _revertWrongFuncCaller();
            }
    }

    function _requireCallerIsBorrowerOperationsOrDefaultPool() internal view {
        if (msg.sender != borrowerOperationsAddress &&
            msg.sender != defaultPoolAddress) {
                _revertWrongFuncCaller();
            }
    }

    function _requireCallerIsBorrowerOperations() internal view {
        if (msg.sender != borrowerOperationsAddress) {
                _revertWrongFuncCaller();
            }
    }

    function _requireCallerIsBOorTroveMorSP() internal view {
        if (msg.sender != borrowerOperationsAddress &&
            msg.sender != troveManagerAddress &&
            msg.sender != stabilityPoolAddress &&
            msg.sender != troveManagerRedemptionsAddress) {
                _revertWrongFuncCaller();
            }
    }

    function _requireCallerIsBOorTroveM() internal view {
        if (msg.sender != borrowerOperationsAddress &&
            msg.sender != troveManagerAddress) {
                _revertWrongFuncCaller();
            }
    }

    function _requireCallerIsWhitelist() internal view {
        if (msg.sender != address(whitelist)) {
            _revertWrongFuncCaller();
        }
    }

    function _revertWrongFuncCaller() internal pure {
        revert("AP: External caller not allowed");
    }

    // should be called by BorrowerOperations or DefaultPool
    // __after__ collateral is transferred to this contract.
    function receiveCollateral(address[] calldata _tokens, uint[] calldata _amounts) external override {
        _requireCallerIsBorrowerOperationsOrDefaultPool();
        poolColl.amounts = _leftSumColls(poolColl, _tokens, _amounts);
        emit ActivePoolBalancesUpdated(_tokens, _amounts);
    }

    // Adds collateral type from whitelist. 
    function addCollateralType(address _collateral) external override {
        _requireCallerIsWhitelist();
        poolColl.tokens.push(_collateral);
        poolColl.amounts.push(0);
    }

}
