// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "./ICollateralReceiver.sol";

/*
 * The Stability Pool holds CUSD tokens deposited by Stability Pool depositors.
 *
 * When a trove is liquidated, then depending on system conditions, some of its CUSD debt gets offset with
 * CUSD in the Stability Pool:  that is, the offset debt evaporates, and an equal amount of CUSD tokens in the Stability Pool is burned.
 *
 * Thus, a liquidation causes each depositor to receive a CUSD loss, in proportion to their deposit as a share of total deposits.
 * They also receive an ETH gain, as the ETH collateral of the liquidated trove is distributed among Stability depositors,
 * in the same proportion.
 *
 * When a liquidation occurs, it depletes every deposit by the same fraction: for example, a liquidation that depletes 40%
 * of the total CUSD in the Stability Pool, depletes 40% of each deposit.
 *
 * A deposit that has experienced a series of liquidations is termed a "compounded deposit": each liquidation depletes the deposit,
 * multiplying it by some factor in range ]0,1[
 *
 * Please see the implementation spec in the proof document, which closely follows on from the compounded deposit / ETH gain derivations:
 * https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 *
 */
interface IStabilityPool is ICollateralReceiver {

    // --- Events ---
    
    event StabilityPoolETHBalanceUpdated(uint _newBalance);
    event StabilityPoolCUSDBalanceUpdated(uint _newBalance);

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolAddressChanged(address _newActivePoolAddress);
    event DefaultPoolAddressChanged(address _newDefaultPoolAddress);
    event CUSDTokenAddressChanged(address _newCUSDTokenAddress);
    event SortedTrovesAddressChanged(address _newSortedTrovesAddress);
    event PriceFeedAddressChanged(address _newPriceFeedAddress);

    event P_Updated(uint _P);
    event S_Updated(uint _S, uint128 _epoch, uint128 _scale);
    event G_Updated(uint _G, uint128 _epoch, uint128 _scale);
    event EpochUpdated(uint128 _currentEpoch);
    event ScaleUpdated(uint128 _currentScale);


    event DepositSnapshotUpdated(address indexed _depositor, uint _P, uint _S, uint _G);
    event UserDepositChanged(address indexed _depositor, uint _newDeposit);

    event ETHGainWithdrawn(address indexed _depositor, uint _ETH, uint _CUSDLoss);
    event EtherSent(address _to, uint _amount);

    // --- Functions ---

    /*
     * Called only once on init, to set addresses of other BOCL contracts
     * Callable only by owner, renounces ownership at the end
     */
    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _activePoolAddress,
        address _CUSDTokenAddress,
        address _sortedTrovesAddress,
        address _whitelistAddress,
        address _troveManagerLiquidationsAddress
    )
        external;

    /*
     * Initial checks:
     * - _amount is not zero
     * ---
     */
    function provideToSP(uint _amount) external;

    /*
     * Initial checks:
     * - _amount is zero or there are no under collateralized troves left in the system
     * - User has a non zero deposit
     * ---
     *
     * If _amount > userDeposit, the user withdraws all of their compounded deposit.
     */
    function withdrawFromSP(uint _amount) external;



    /*
     * Initial checks:
     * - Caller is TroveManager
     * ---
     * Cancels out the specified debt against the CUSD contained in the Stability Pool (as far as possible)
     * and transfers the Trove's ETH collateral from ActivePool to StabilityPool.
     * Only called by liquidation functions in the TroveManager.
     */
    function offset(uint _debt, address[] memory _assets, uint[] memory _amountsAdded) external;

//    /*
//     * Returns the total amount of ETH held by the pool, accounted in an internal variable instead of `balance`,
//     * to exclude edge cases like ETH received from a self-destruct.
//     */
//    function getETH() external view returns (uint);
    
     //*
//     * Calculates and returns the total gains a depositor has accumulated 
//     */
    function  getDepositorGains(address _depositor) external view returns (address[] memory assets, uint[] memory amounts);


    /*
     * Returns the total amount of VC held by the pool, accounted for by multipliying the
     * internal balances of collaterals by the price that is found at the time getVC() is called.
     */
    function getVC() external view returns (uint);

    /*
     * Returns CUSD held in the pool. Changes when users deposit/withdraw, and when Trove debt is offset.
     */
    function getTotalCUSDDeposits() external view returns (uint);


    /*
     * Return the user's compounded deposit.
     */
    function getCompoundedCUSDDeposit(address _depositor) external view returns (uint);


    /*
     * Add collateral type to totalColl 
     */
    function addCollateralType(address _collateral) external;

    function getDepositSnapshotS(address depositor, address collateral) external view returns (uint);

    function getCollateral(address _collateral) external view returns (uint);

    function getAllCollateral() external view returns (address[] memory, uint256[] memory);

}
