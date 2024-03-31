// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/ICUSDToken.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/ICommunityIssuance.sol";
import "./Interfaces/IWhitelist.sol";
import "./Interfaces/IERC20.sol";
import "./Interfaces/IWAsset.sol";
import "./Dependencies/PoolBase.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/LiquitySafeMath128.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/SafeERC20.sol";


/*
 * The Stability Pool holds CUSD tokens deposited by Stability Pool depositors.
 *
 * When a trove is liquidated, then depending on system conditions, some of its CUSD debt gets offset with
 * CUSD in the Stability Pool: that is, the offset debt evaporates, and an equal amount of CUSD tokens in the Stability Pool is burned.
 *
 * Thus, a liquidation causes each depositor to receive a CUSD loss, in proportion to their deposit as a share of total deposits.
 * They also receive an Collateral gain, as the amount of collateral of the liquidated trove is distributed among Stability depositors,
 * in the same proportion.
 *
 * When a liquidation occurs, it depletes every deposit by the same fraction: for example, a liquidation that depletes 40%
 * of the total CUSD in the Stability Pool, depletes 40% of each deposit.
 *
 * A deposit that has experienced a series of liquidations is termed a "compounded deposit": each liquidation depletes the deposit,
 * multiplying it by some factor in range ]0,1[
 *
 *
 * --- IMPLEMENTATION ---
 *
 * We use a highly scalable method of tracking deposits and Collateral gains that has O(1) complexity.
 *
 * When a liquidation occurs, rather than updating each depositor's deposit and Collateral gain, we simply update two state variables:
 * a product P, and a sum S. These are kept track for each type of collateral.
 *
 * A mathematical manipulation allows us to factor out the initial deposit, and accurately track all depositors' compounded deposits
 * and accumulated Collateral amount gains over time, as liquidations occur, using just these two variables P and S. When depositors join the
 * Stability Pool, they get a snapshot of the latest P and S: P_t and S_t, respectively.
 *
 * The formula for a depositor's accumulated Collateral amount gain is derived here:
 * https://github.com/liquity/dev/blob/main/packages/contracts/mathProofs/Scalable%20Compounding%20Stability%20Pool%20Deposits.pdf
 *
 * For a given deposit d_t, the ratio P/P_t tells us the factor by which a deposit has decreased since it joined the Stability Pool,
 * and the term d_t * (S - S_t)/P_t gives us the deposit's total accumulated Collateral amount gain.
 *
 * Each liquidation updates the product P and sum S. After a series of liquidations, a compounded deposit and corresponding Collateral amount gain
 * can be calculated using the initial deposit, the depositor’s snapshots of P and S, and the latest values of P and S.
 *
 * Any time a depositor updates their deposit (withdrawal, top-up) their accumulated Collateral amount gain is paid out, their new deposit is recorded
 * (based on their latest compounded deposit and modified by the withdrawal/top-up), and they receive new snapshots of the latest P and S.
 * Essentially, they make a fresh deposit that overwrites the old one.
 *
 *
 * --- SCALE FACTOR ---
 *
 * Since P is a running product in range ]0,1] that is always-decreasing, it should never reach 0 when multiplied by a number in range ]0,1[.
 * Unfortunately, Solidity floor division always reaches 0, sooner or later.
 *
 * A series of liquidations that nearly empty the Pool (and thus each multiply P by a very small number in range ]0,1[ ) may push P
 * to its 18 digit decimal limit, and round it to 0, when in fact the Pool hasn't been emptied: this would break deposit tracking.
 *
 * So, to track P accurately, we use a scale factor: if a liquidation would cause P to decrease to <1e-9 (and be rounded to 0 by Solidity),
 * we first multiply P by 1e9, and increment a currentScale factor by 1.
 *
 * The added benefit of using 1e9 for the scale factor (rather than 1e18) is that it ensures negligible precision loss close to the
 * scale boundary: when P is at its minimum value of 1e9, the relative precision loss in P due to floor division is only on the
 * order of 1e-9.
 *
 * --- EPOCHS ---
 *
 * Whenever a liquidation fully empties the Stability Pool, all deposits should become 0. However, setting P to 0 would make P be 0
 * forever, and break all future reward calculations.
 *
 * So, every time the Stability Pool is emptied by a liquidation, we reset P = 1 and currentScale = 0, and increment the currentEpoch by 1.
 *
 * --- TRACKING DEPOSIT OVER SCALE CHANGES AND EPOCHS ---
 *
 * When a deposit is made, it gets snapshots of the currentEpoch and the currentScale.
 *
 * When calculating a compounded deposit, we compare the current epoch to the deposit's epoch snapshot. If the current epoch is newer,
 * then the deposit was present during a pool-emptying liquidation, and necessarily has been depleted to 0.
 *
 * Otherwise, we then compare the current scale to the deposit's scale snapshot. If they're equal, the compounded deposit is given by d_t * P/P_t.
 * If it spans one scale change, it is given by d_t * P/(P_t * 1e9). If it spans more than one scale change, we define the compounded deposit
 * as 0, since it is now less than 1e-9'th of its initial value (e.g. a deposit of 1 billion CUSD has depleted to < 1 CUSD).
 *
 *
 *  --- TRACKING DEPOSITOR'S COLLATERAL AMOUNT GAIN OVER SCALE CHANGES AND EPOCHS ---
 *
 * In the current epoch, the latest value of S is stored upon each scale change, and the mapping (scale -> S) is stored for each epoch.
 *
 * This allows us to calculate a deposit's accumulated Collateral amount gain, during the epoch in which the deposit was non-zero and earned Collateral amount.
 *
 * We calculate the depositor's accumulated Collateral amount gain for the scale at which they made the deposit, using the Collateral amount gain formula:
 * e_1 = d_t * (S - S_t) / P_t
 *
 * and also for scale after, taking care to divide the latter by a factor of 1e9:
 * e_2 = d_t * S / (P_t * 1e9)
 *
 * The gain in the second scale will be full, as the starting point was in the previous scale, thus no need to subtract anything.
 * The deposit therefore was present for reward events from the beginning of that second scale.
 *
 *        S_i-S_t + S_{i+1}
 *      .<--------.------------>
 *      .         .
 *      . S_i     .   S_{i+1}
 *   <--.-------->.<----------->
 *   S_t.         .
 *   <->.         .
 *      t         .
 *  |---+---------|-------------|-----...
 *         i            i+1
 *
 * The sum of (e_1 + e_2) captures the depositor's total accumulated Collateral amount gain, handling the case where their
 * deposit spanned one scale change. We only care about gains across one scale change, since the compounded
 * deposit is defined as being 0 once it has spanned more than one scale change.
 *
 *
 * --- UPDATING P WHEN A LIQUIDATION OCCURS ---
 *
 * Please see the implementation spec in the proof document, which closely follows on from the compounded deposit / Collateral amount gain derivations:
 * https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 *
 *
 *
 */
contract StabilityPool is PoolBase, OwnableUpgradeable, CheckContract, IStabilityPool {
    using LiquitySafeMath128 for uint128;
    using SafeERC20 for IERC20;

    string public constant NAME = "StabilityPool";

    address internal troveManagerLiquidationsAddress;
    address internal whitelistAddress;

    IBorrowerOperations internal borrowerOperations;
    ITroveManager internal troveManager;
    ICUSDToken internal CUSDToken;
    // Needed to check if there are pending liquidations
    ISortedTroves internal sortedTroves;

    // Tracker for CUSD held in the pool. Changes when users deposit/withdraw, and when Trove debt is offset.
    uint256 internal totalCUSDDeposits;

    // totalColl.tokens and totalColl.amounts should be the same length and always be the same length
    // as whitelist.validCollaterals(). Anytime a new collateral is added to whitelist
    // both lists are lengthened
    newColls internal totalColl;

    // --- Data structures ---


    struct Deposit {
        uint256 initialValue;
        address frontEndTag;
    }

    struct Snapshots {
        mapping(address => uint256) S;
        uint256 P;
        uint256 G;
        uint128 scale;
        uint128 epoch;
    }

    mapping(address => Deposit) public deposits; // depositor address -> Deposit struct

    /* depositSnapshots maintains an entry for each depositor
     * that tracks P, S, G, scale, and epoch.
     * depositor's snapshot is updated only when they
     * deposit or withdraw from stability pool
     * and to calculate how much Collateral amount the depositor is entitled to
     */
    mapping(address => Snapshots) public depositSnapshots; // depositor address -> snapshots struct

    /*  Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
     * after a series of liquidations have occurred, each of which cancel some CUSD debt with the deposit.
     *
     * During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
     * is the snapshot of P taken at the instant the deposit was made. 18-digit decimal.
     */
    uint256 public P;

    uint256 public constant SCALE_FACTOR = 1e9;

    // Each time the scale of P shifts by SCALE_FACTOR, the scale is incremented by 1
    uint128 public currentScale;

    // With each offset that fully empties the Pool, the epoch is incremented by 1
    uint128 public currentEpoch;

    /* Collateral amount Gain sum 'S': During its lifetime, each deposit d_t earns an Collateral amount gain of ( d_t * [S - S_t] )/P_t,
     * where S_t is the depositor's snapshot of S taken at the time t when the deposit was made.
     *
     * The 'S' sums are stored in a nested mapping (epoch => scale => sum):
     *
     * - The inner mapping records the sum S at different scales
     * - The middle mapping records the (scale => sum) mappings, for different epochs.
     * - The outer mapping records the (collateralType => (epoch => (scale => sum)) mappings
     */
    mapping(address => mapping(uint128 => mapping(uint128 => uint256))) public epochToScaleToSum;

    mapping(uint128 => mapping(uint128 => uint256)) public epochToScaleToG;


    // Error trackers for the error correction in the offset calculation
    uint256[] public lastAssetError_Offset;
    uint256 public lastCUSDLossError_Offset;

    // --- Events ---

    event StabilityPoolBalanceUpdated(address[] assets, uint256[] amounts);
    event StabilityPoolBalancesUpdated(address[] assets, uint256[] amounts);
    event StabilityPoolCUSDBalanceUpdated(uint256 _newBalance);

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolAddressChanged(address _newActivePoolAddress);
    event DefaultPoolAddressChanged(address _newDefaultPoolAddress);
    event CUSDTokenAddressChanged(address _newCUSDTokenAddress);
    event SortedTrovesAddressChanged(address _newSortedTrovesAddress);
    event CommunityIssuanceAddressChanged(address _newCommunityIssuanceAddress);

    event P_Updated(uint256 _P);
    event S_Updated(address _asset, uint256 _S, uint128 _epoch, uint128 _scale);
    event G_Updated(uint256 _G, uint128 _epoch, uint128 _scale);
    event EpochUpdated(uint128 _currentEpoch);
    event ScaleUpdated(uint128 _currentScale);


    event DepositSnapshotUpdated(address indexed _depositor, uint256 _P, uint256 _G);
    event UserDepositChanged(address indexed _depositor, uint256 _newDeposit);


    event GainsWithdrawn(
        address indexed _depositor,
        address[] collaterals,
        uint256[] _amounts,
        uint256 _CUSDLoss
    );
    event CollateralSent(address _to, address[] _collaterals, uint256[] _amounts);

    // --- Contract setters ---

    function setUp() external {
		__Ownable_init();
	}

    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _activePoolAddress,
        address _CUSDTokenAddress,
        address _sortedTrovesAddress,
        address _whitelistAddress,
        address _troveManagerLiquidationsAddress
    ) external override onlyOwner {
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_activePoolAddress);
        checkContract(_CUSDTokenAddress);
        checkContract(_sortedTrovesAddress);
        checkContract(_whitelistAddress);
        checkContract(_troveManagerLiquidationsAddress);

        borrowerOperations = IBorrowerOperations(_borrowerOperationsAddress);
        troveManager = ITroveManager(_troveManagerAddress);
        activePool = IActivePool(_activePoolAddress);
        CUSDToken = ICUSDToken(_CUSDTokenAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        whitelist = IWhitelist(_whitelistAddress);

        troveManagerLiquidationsAddress = _troveManagerLiquidationsAddress;
        whitelistAddress = _whitelistAddress;
        P = DECIMAL_PRECISION;
        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
        emit CUSDTokenAddressChanged(_CUSDTokenAddress);
        emit SortedTrovesAddressChanged(_sortedTrovesAddress);

        renounceOwnership();
    }

    // --- Getters for public variables. Required by IPool interface --- 

    // total VC of collateral in Stability Pool
    function getVC() external view override returns (uint256) {
        return _getVCColls(totalColl);
    }

    function getCollateral(address _collateral) external view override returns (uint256) {
        uint256 collateralIndex = whitelist.getIndex(_collateral);
        return totalColl.amounts[collateralIndex];
    }

    /*
     * Returns all collateral balances in state. Not necessarily the contract's actual balances.
     */
    function getAllCollateral() external view override returns (address[] memory, uint256[] memory) {
        return (totalColl.tokens, totalColl.amounts);
    }

    function getTotalCUSDDeposits() external view override returns (uint256) {
        return totalCUSDDeposits;
    }

    // --- External Depositor Functions ---

    /*  provideToSP():
     *
     */
    function provideToSP(uint256 _amount) external override {
        _requireNonZeroAmount(_amount);

        uint256 initialDeposit = deposits[msg.sender].initialValue;


        (address[] memory assets, uint256[] memory amounts) = getDepositorGains(msg.sender);
        uint256 compoundedCUSDDeposit = getCompoundedCUSDDeposit(msg.sender);
        uint256 CUSDLoss = initialDeposit.sub(compoundedCUSDDeposit); // Needed only for event log


        // just pulls CUSD into the pool, updates totalCUSDDeposits variable for the stability pool
        // and throws an event
        _sendCUSDtoStabilityPool(msg.sender, _amount);

        uint256 newDeposit = compoundedCUSDDeposit.add(_amount);
        _updateDepositAndSnapshots(msg.sender, newDeposit);
        emit UserDepositChanged(msg.sender, newDeposit);

        emit GainsWithdrawn(msg.sender, assets, amounts, CUSDLoss); // CUSD Loss required for event log

        _sendGainsToDepositor(msg.sender, assets, amounts);
    }

    /*  withdrawFromSP():
     *
     *
     * If _amount > userDeposit, the user withdraws all of their compounded deposit.
     */
    function withdrawFromSP(uint256 _amount) external override {
        if (_amount != 0) {
            _requireNoUnderCollateralizedTroves();
        }
        uint256 initialDeposit = deposits[msg.sender].initialValue;
        _requireUserHasDeposit(initialDeposit);


        (address[] memory assets, uint256[] memory amounts) = getDepositorGains(msg.sender);

        uint256 compoundedCUSDDeposit = getCompoundedCUSDDeposit(msg.sender);

        uint256 CUSDtoWithdraw = LiquityMath._min(_amount, compoundedCUSDDeposit);
        uint256 CUSDLoss = initialDeposit.sub(compoundedCUSDDeposit); // Needed only for event log


        _sendCUSDToDepositor(msg.sender, CUSDtoWithdraw);

        // Update deposit
        uint256 newDeposit = compoundedCUSDDeposit.sub(CUSDtoWithdraw);
        _updateDepositAndSnapshots(msg.sender, newDeposit);
        emit UserDepositChanged(msg.sender, newDeposit);

        emit GainsWithdrawn(msg.sender, assets, amounts, CUSDLoss); // CUSD Loss required for event log

        _sendGainsToDepositor(msg.sender, assets, amounts);
    }


    // --- Liquidation functions ---

    /*
     * Cancels out the specified debt against the CUSD contained in the Stability Pool (as far as possible)
     * and transfers the Trove's collateral from ActivePool to StabilityPool.
     * Only called by liquidation functions in the TroveManager.
     */
    function offset(
        uint256 _debtToOffset,
        address[] memory _tokens,
        uint256[] memory _amountsAdded
    ) external override {
        _requireCallerIsTML();
        uint256 totalCUSD = totalCUSDDeposits; // cached to save an SLOAD
        if (totalCUSD == 0 || _debtToOffset == 0) {
            return;
        }


        (
            uint256[] memory AssetGainPerUnitStaked,
            uint256 CUSDLossPerUnitStaked
        ) = _computeRewardsPerUnitStaked(_tokens, _amountsAdded, _debtToOffset, totalCUSD);

        _updateRewardSumAndProduct(_tokens, AssetGainPerUnitStaked, CUSDLossPerUnitStaked); // updates S and P
        _moveOffsetCollAndDebt(_tokens, _amountsAdded, _debtToOffset);
    }

    // --- Offset helper functions ---


    /*
    * Compute the CUSD and Collateral amount rewards. Uses a "feedback" error correction, to keep
    * the cumulative error in the P and S state variables low:
    *
    * 1) Form numerators which compensate for the floor division errors that occurred the last time this
    * function was called.
    * 2) Calculate "per-unit-staked" ratios.
    * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
    * 4) Store these errors for use in the next correction when this function is called.
    * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
    */
    function _computeRewardsPerUnitStaked(
        address[] memory _tokens,
        uint256[] memory _amountsAdded,
        uint256 _debtToOffset,
        uint256 _totalCUSDDeposits
    ) internal returns (uint256[] memory AssetGainPerUnitStaked, uint256 CUSDLossPerUnitStaked) {
        uint256 amountsLen = _amountsAdded.length;
        uint256[] memory CollateralNumerators = new uint256[](amountsLen);
        uint256 currentP = P;

        for (uint256 i; i < amountsLen; ++i) {
            uint256 tokenIDX = whitelist.getIndex(_tokens[i]);
            CollateralNumerators[i] = _amountsAdded[i].mul(DECIMAL_PRECISION).add(
                lastAssetError_Offset[tokenIDX]
            );
        }

        require(_debtToOffset <= _totalCUSDDeposits, "SP:This debt less than totalCUSD");
        if (_debtToOffset == _totalCUSDDeposits) {
            CUSDLossPerUnitStaked = DECIMAL_PRECISION; // When the Pool depletes to 0, so does each deposit
            lastCUSDLossError_Offset = 0;
        } else {
            uint256 CUSDLossNumerator = _debtToOffset.mul(DECIMAL_PRECISION).sub(
                lastCUSDLossError_Offset
            );
            /*
             * Add 1 to make error in quotient positive. We want "slightly too much" CUSD loss,
             * which ensures the error in any given compoundedCUSDDeposit favors the Stability Pool.
             */
            CUSDLossPerUnitStaked = (CUSDLossNumerator.div(_totalCUSDDeposits)).add(1);
            lastCUSDLossError_Offset = (CUSDLossPerUnitStaked.mul(_totalCUSDDeposits)).sub(
                CUSDLossNumerator
            );
        }

        AssetGainPerUnitStaked = new uint256[](_amountsAdded.length);
        for (uint256 i; i < amountsLen; ++i) {
            AssetGainPerUnitStaked[i] = CollateralNumerators[i].mul(currentP).div(_totalCUSDDeposits);
        }

        for (uint256 i; i < amountsLen; ++i) {
            uint256 tokenIDX = whitelist.getIndex(_tokens[i]);
            lastAssetError_Offset[tokenIDX] = CollateralNumerators[i].sub(
                AssetGainPerUnitStaked[i].mul(_totalCUSDDeposits).div(currentP)
            );
        }

    }

    // Update the Stability Pool reward sum S and product P
    function _updateRewardSumAndProduct(
        address[] memory _assets,
        uint256[] memory _AssetGainPerUnitStaked,
        uint256 _CUSDLossPerUnitStaked
    ) internal {
        uint256 currentP = P;
        uint256 newP;

        require(_CUSDLossPerUnitStaked <= DECIMAL_PRECISION, "SP: CUSDLoss < 1");
        /*
         * The newProductFactor is the factor by which to change all deposits, due to the depletion of Stability Pool CUSD in the liquidation.
         * We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - CUSDLossPerUnitStaked)
         */
        uint256 newProductFactor = uint256(DECIMAL_PRECISION).sub(_CUSDLossPerUnitStaked);

        uint128 currentScaleCached = currentScale;
        uint128 currentEpochCached = currentEpoch;

        /*
         * Calculate the new S first, before we update P.
         * The Collateral amount gain for any given depositor from a liquidation depends on the value of their deposit
         * (and the value of totalDeposits) prior to the Stability being depleted by the debt in the liquidation.
         *
         * Since S corresponds to Collateral amount gain, and P to deposit loss, we update S first.
         */
        uint256 assetsLen = _assets.length;
        for (uint256 i; i < assetsLen; ++i) {
            address asset = _assets[i];
            
            // uint256 marginalAssetGain = _AssetGainPerUnitStaked[i]; only used once, named here for clarity.
            uint256 currentAssetS = epochToScaleToSum[asset][currentEpochCached][currentScaleCached];
            uint256 newAssetS = currentAssetS.add(_AssetGainPerUnitStaked[i]);

            epochToScaleToSum[asset][currentEpochCached][currentScaleCached] = newAssetS;
            emit S_Updated(asset, newAssetS, currentEpochCached, currentScaleCached);
        }

        // If the Stability Pool was emptied, increment the epoch, and reset the scale and product P
        if (newProductFactor == 0) {
            currentEpoch = currentEpochCached.add(1);
            emit EpochUpdated(currentEpoch);
            currentScale = 0;
            emit ScaleUpdated(currentScale);
            newP = DECIMAL_PRECISION;

            // If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
        } else if (currentP.mul(newProductFactor).div(DECIMAL_PRECISION) < SCALE_FACTOR) {
            newP = currentP.mul(newProductFactor).mul(SCALE_FACTOR).div(DECIMAL_PRECISION);
            currentScale = currentScaleCached.add(1);
            emit ScaleUpdated(currentScale);
        } else {
            newP = currentP.mul(newProductFactor).div(DECIMAL_PRECISION);
        }

        require(newP != 0, "SP: P = 0");
        P = newP;
        emit P_Updated(newP);
    }

    // Internal function to move offset collateral and debt between pools. 
    function _moveOffsetCollAndDebt(
        address[] memory _collsToAdd,
        uint256[] memory _amountsToAdd,
        uint256 _debtToOffset
    ) internal {
        IActivePool activePoolCached = activePool;
        // Cancel the liquidated CUSD debt with the CUSD in the stability pool
        activePoolCached.decreaseCUSDDebt(_debtToOffset);
        _decreaseCUSD(_debtToOffset);

        // Burn the debt that was successfully offset
        CUSDToken.burn(address(this), _debtToOffset);

        activePoolCached.sendCollaterals(address(this), _collsToAdd, _amountsToAdd);
    }

    // Decreases CUSD Stability pool balance.
    function _decreaseCUSD(uint256 _amount) internal {
        uint256 newTotalCUSDDeposits = totalCUSDDeposits.sub(_amount);
        totalCUSDDeposits = newTotalCUSDDeposits;
        emit StabilityPoolCUSDBalanceUpdated(newTotalCUSDDeposits);
    }

    // --- Reward calculator functions for depositor and front end ---

    /* Calculates the gains earned by the deposit since its last snapshots were taken.
     * Given by the formula:  E = d0 * (S - S(0))/P(0)
     * where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
     * d0 is the last recorded deposit value.
     * returns assets, amounts
     */
    function getDepositorGains(address _depositor)
        public
        view
        override
        returns (address[] memory, uint256[] memory)
    {
        uint256 initialDeposit = deposits[_depositor].initialValue;

        if (initialDeposit == 0) {
            address[] memory emptyAddress = new address[](0);
            uint256[] memory emptyUint = new uint256[](0);
            return (emptyAddress, emptyUint);
        }

        Snapshots storage snapshots = depositSnapshots[_depositor];

        return _calculateGains(initialDeposit, snapshots);
    }

    // get gains on each possible asset by looping through
    // assets with _getGainFromSnapshots function
    function _calculateGains(uint256 initialDeposit, Snapshots storage snapshots)
        internal
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = whitelist.getValidCollateral();
        uint256 assetsLen = assets.length;
        amounts = new uint256[](assetsLen);
        for (uint256 i; i < assetsLen; ++i) {
            amounts[i] = _getGainFromSnapshots(initialDeposit, snapshots, assets[i]);
        }
    }

    // gets the gain in S for a given asset
    // for a user who deposited initialDeposit
    function _getGainFromSnapshots(
        uint256 initialDeposit,
        Snapshots storage snapshots,
        address asset
    ) internal view returns (uint256) {
        /*
         * Grab the sum 'S' from the epoch at which the stake was made. The Collateral amount gain may span up to one scale change.
         * If it does, the second portion of the Collateral amount gain is scaled by 1e9.
         * If the gain spans no scale change, the second portion will be 0.
         */
        uint256 S_Snapshot = snapshots.S[asset];
        uint256 P_Snapshot = snapshots.P;

        uint256 firstPortion = epochToScaleToSum[asset][snapshots.epoch][snapshots.scale].sub(
            S_Snapshot
        );        
        uint256 secondPortion = epochToScaleToSum[asset][snapshots.epoch][snapshots.scale.add(1)]
            .div(SCALE_FACTOR);

        uint256 assetGain = initialDeposit.mul(firstPortion.add(secondPortion)).div(P_Snapshot).div(
            DECIMAL_PRECISION
        );
        
        return assetGain;
    }




    // --- Compounded deposit and compounded front end stake ---

    /*
     * Return the user's compounded deposit. Given by the formula:  d = d0 * P/P(0)
     * where P(0) is the depositor's snapshot of the product P, taken when they last updated their deposit.
     */
    function getCompoundedCUSDDeposit(address _depositor) public view override returns (uint256) {
        uint256 initialDeposit = deposits[_depositor].initialValue;
        if (initialDeposit == 0) {
            return 0;
        }

        Snapshots storage snapshots = depositSnapshots[_depositor];

        uint256 compoundedDeposit = _getCompoundedStakeFromSnapshots(initialDeposit, snapshots);
        return compoundedDeposit;
    }



    // Internal function, used to calculate compounded deposits and compounded front end stakes.
    // returns 0 if the snapshots were taken prior to a a pool-emptying event
    // also returns zero if scaleDiff (currentScale.sub(scaleSnapshot)) is more than 2 or
    // If the scaleDiff is 0 or 1,
    // then adjust for changes in P and scale changes to calculate a compoundedStake.
    // IF the final compoundedStake isn't less than a billionth of the initial stake, return it.this
    // otherwise, just return 0.
    function _getCompoundedStakeFromSnapshots(uint256 initialStake, Snapshots storage snapshots)
        internal
        view
        returns (uint256)
    {
        uint256 snapshot_P = snapshots.P;
        uint128 scaleSnapshot = snapshots.scale;
        uint128 epochSnapshot = snapshots.epoch;

        // If stake was made before a pool-emptying event, then it has been fully cancelled with debt -- so, return 0
        if (epochSnapshot < currentEpoch) {
            return 0;
        }

        uint256 compoundedStake;
        uint128 scaleDiff = currentScale.sub(scaleSnapshot);

        /* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
         * account for it. If more than one scale change was made, then the stake has decreased by a factor of
         * at least 1e-9 -- so return 0.
         */
        if (scaleDiff == 0) {
            compoundedStake = initialStake.mul(P).div(snapshot_P);
        } else if (scaleDiff == 1) {
            compoundedStake = initialStake.mul(P).div(snapshot_P).div(SCALE_FACTOR);
        } else {
            // if scaleDiff >= 2
            compoundedStake = 0;
        }

        /*
         * If compounded deposit is less than a billionth of the initial deposit, return 0.
         *
         * NOTE: originally, this line was in place to stop rounding errors making the deposit too large. However, the error
         * corrections should ensure the error in P "favors the Pool", i.e. any given compounded deposit should slightly less
         * than it's theoretical value.
         *
         * Thus it's unclear whether this line is still really needed.
         */
        if (compoundedStake < initialStake.div(1e9)) {
            return 0;
        }

        return compoundedStake;
    }

    // --- Sender functions for CUSD deposit, Collateral gains ---

    // Transfer the CUSD tokens from the user to the Stability Pool's address, and update its recorded CUSD
    function _sendCUSDtoStabilityPool(address _address, uint256 _amount) internal {
        CUSDToken.sendToPool(_address, address(this), _amount);
        uint256 newTotalCUSDDeposits = totalCUSDDeposits.add(_amount);
        totalCUSDDeposits = newTotalCUSDDeposits;
        emit StabilityPoolCUSDBalanceUpdated(newTotalCUSDDeposits);
    }

    function _sendGainsToDepositor(
        address _to,
        address[] memory assets,
        uint256[] memory amounts
    ) internal {
        uint256 assetsLen = assets.length;
        require(assetsLen == amounts.length, "SP:Length mismatch");
        for (uint256 i; i < assetsLen; ++i) {
            uint256 thisAmounts = amounts[i];
            if (thisAmounts == 0) {
                continue;
            }
            address thisAsset = assets[i];
            if (whitelist.isWrapped(thisAsset)) {
                // In this case update the rewards from the treasury to the caller 
                IWAsset(thisAsset).endTreasuryReward(address(this), thisAmounts);
                // unwrapFor ends the rewards for the caller and transfers the tokens to the _to param. 
                IWAsset(thisAsset).unwrapFor(address(this), _to, thisAmounts);
            } else {
                IERC20(thisAsset).safeTransfer(_to, thisAmounts);
            }
        }
        totalColl.amounts = _leftSubColls(totalColl, assets, amounts);
    }

    // Send CUSD to user and decrease CUSD in Pool
    function _sendCUSDToDepositor(address _depositor, uint256 CUSDWithdrawal) internal {
        if (CUSDWithdrawal == 0) {
            return;
        }

        CUSDToken.returnFromPool(address(this), _depositor, CUSDWithdrawal);
        _decreaseCUSD(CUSDWithdrawal);
    }


    // --- Stability Pool Deposit Functionality ---


    // if _newValue is zero, delete snapshot for given _depositor and emit event
    // otherwise, add an entry or update existing entry for _depositor in the depositSnapshots
    // with current values for P, S, G, scale and epoch and then emit event.
    function _updateDepositAndSnapshots(address _depositor, uint256 _newValue) internal {
        deposits[_depositor].initialValue = _newValue;

        if (_newValue == 0) {
            delete deposits[_depositor].frontEndTag;
            address[] memory colls = whitelist.getValidCollateral();
            uint256 collsLen = colls.length;
            for (uint256 i; i < collsLen; ++i) {
                depositSnapshots[_depositor].S[colls[i]] = 0;
            }
            depositSnapshots[_depositor].P = 0;
            depositSnapshots[_depositor].G = 0;
            depositSnapshots[_depositor].epoch = 0;
            depositSnapshots[_depositor].scale = 0;
            emit DepositSnapshotUpdated(_depositor, 0, 0);
            return;
        }
        uint128 currentScaleCached = currentScale;
        uint128 currentEpochCached = currentEpoch;
        uint256 currentP = P;

        address[] memory allColls = whitelist.getValidCollateral();

        // Get S and G for the current epoch and current scale
        uint256 allCollsLen = allColls.length;
        for (uint256 i; i < allCollsLen; ++i) {
            address token = allColls[i];
            uint256 currentSForToken = epochToScaleToSum[token][currentEpochCached][
                currentScaleCached
            ];
            depositSnapshots[_depositor].S[token] = currentSForToken;
        }

        uint256 currentG = epochToScaleToG[currentEpochCached][currentScaleCached];

        // Record new snapshots of the latest running product P, sum S, and sum G, for the depositor
        depositSnapshots[_depositor].P = currentP;
        depositSnapshots[_depositor].G = currentG;
        depositSnapshots[_depositor].scale = currentScaleCached;
        depositSnapshots[_depositor].epoch = currentEpochCached;

        emit DepositSnapshotUpdated(_depositor, currentP, currentG);
    }


    // --- 'require' functions ---

    function _requireNoUnderCollateralizedTroves() internal view {
        address lowestTrove = sortedTroves.getLast(); // todo confirm this is ok
        uint256 ICR = troveManager.getCurrentICR(lowestTrove);
        require(ICR >= MCR, "SP:No Withdraw when troveICR<MCR");
    }

    function _requireUserHasDeposit(uint256 _initialDeposit) internal pure {
        require(_initialDeposit != 0, "SP: require nonzero deposit");
    }

    function _requireUserHasNoDeposit(address _address) internal view {
        uint256 initialDeposit = deposits[_address].initialValue;
        require(initialDeposit == 0, "SP: User must have no deposit");
    }

    function _requireNonZeroAmount(uint256 _amount) internal pure {
        require(_amount != 0, "SP: Amount must be non-zero");
    }


    function _requireCallerIsWhitelist() internal view {
        if (msg.sender != whitelistAddress) {
            _revertWrongFuncCaller();
        }
    }

    function _requireCallerIsActivePool() internal view {
        if (msg.sender != address(activePool)) {
            _revertWrongFuncCaller();
        }
    }

    function _requireCallerIsTML() internal view {
        if (msg.sender != address(troveManagerLiquidationsAddress)) {
            _revertWrongFuncCaller();
        }
    }

    function _revertWrongFuncCaller() internal pure {
        revert("SP: External caller not allowed");
    }

    // Should be called by ActivePool
    // __after__ collateral is transferred to this contract from Active Pool
    function receiveCollateral(address[] memory _tokens, uint256[] memory _amounts)
        external
        override
    {
        _requireCallerIsActivePool();
        totalColl.amounts = _leftSumColls(totalColl, _tokens, _amounts);
        emit StabilityPoolBalancesUpdated(_tokens, _amounts);
    }

    // should be called anytime a collateral is added to whitelist
    function addCollateralType(address _collateral) external override {
        _requireCallerIsWhitelist();
        lastAssetError_Offset.push(0);
        totalColl.tokens.push(_collateral);
        totalColl.amounts.push(0);
    }

    // Gets reward snapshot S for certain collateral and depositor. 
    function getDepositSnapshotS(address _depositor, address _collateral)
        external
        view
        override
        returns (uint256)
    {
        return depositSnapshots[_depositor].S[_collateral];
    }
}
