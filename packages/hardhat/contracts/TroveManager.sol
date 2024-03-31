// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ICUSDToken.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/ITreasury.sol";
import "./Interfaces/IWhitelist.sol";
import "./Interfaces/ITroveManagerLiquidations.sol";
import "./Interfaces/ITroveManagerRedemptions.sol";
import "./Interfaces/IERC20.sol";
import "./Dependencies/TroveManagerBase.sol";


/** 
 * Trove Manager is the contract which deals with the state of a user's trove. It has all the 
 * external functions for liquidations, redemptions, as well as functions called by 
 * BorrowerOperations function calls. 
 */

contract TroveManager is TroveManagerBase, ITroveManager, ReentrancyGuardUpgradeable {
    
    address internal borrowerOperationsAddress;

    IStabilityPool internal stabilityPoolContract;

    ITroveManager internal troveManager;

    ICUSDToken internal CUSDTokenContract;

    ITreasury internal BOCTreasuryContract;

    ITroveManagerRedemptions internal troveManagerRedemptions;

    ITroveManagerLiquidations internal troveManagerLiquidations;

    address internal gasPoolAddress;
    address internal troveManagerRedemptionsAddress;
    address internal troveManagerLiquidationsAddress;

    ISortedTroves internal sortedTroves;

    ICollSurplusPool internal collSurplusPool;

    bytes32 constant public NAME = "TroveManager";

    // --- Data structures ---

    uint constant internal SECONDS_IN_ONE_MINUTE = 60;

    /*
     * Half-life of 12h. 12h = 720 min
     * (1/2) = d^720 => d = (1/2)^(1/720)
     */
    uint constant public MINUTE_DECAY_FACTOR = 999037758833783000;
    uint constant public MAX_BORROWING_FEE = DECIMAL_PRECISION / 100 * 5; // 5%

    // During bootsrap period redemptions are not allowed
    uint constant public BOOTSTRAP_PERIOD = 14 days;

    uint public baseRate;

    // The timestamp of the latest fee operation (redemption or new CUSD issuance)
    uint public lastFeeOperationTime;

    mapping (address => Trove) Troves;

    // uint public totalStakes;
    mapping (address => uint) public totalStakes;

    // Snapshot of the value of totalStakes, taken immediately after the latest liquidation
    mapping (address => uint) public totalStakesSnapshot;

    // Snapshot of the total collateral across the ActivePool and DefaultPool, immediately after the latest liquidation.
    mapping (address => uint) public totalCollateralSnapshot;

    /*
    * L_Coll and L_CUSDDebt track the sums of accumulated liquidation rewards per unit staked. Each collateral type has
    * its own L_Coll and L_CUSDDebt.
    * During its lifetime, each stake earns:
    *
    * A Collateral gain of ( stake * [L_Coll[coll] - L_Coll[coll](0)] )
    * A CUSDDebt increase  of ( stake * [L_CUSDDebt - L_CUSDDebt(0)] )
    *
    * Where L_Coll[coll](0) and L_CUSDDebt(0) are snapshots of L_Coll[coll] and L_CUSDDebt for the active Trove taken at the instant the stake was made
    */
    mapping (address => uint) private L_Coll;
    mapping (address => uint) public L_CUSDDebt;

    // Map addresses with active troves to their RewardSnapshot
    mapping (address => RewardSnapshot) rewardSnapshots;

    // Object containing the reward snapshots for a given active trove
    struct RewardSnapshot {
        mapping(address => uint) CollRewards;
        mapping(address => uint) CUSDDebts;
    }

    // Array of all active trove addresses - used to to compute an approximate hint off-chain, for the sorted list insertion
    address[] private TroveOwners;

    // Error trackers for the trove redistribution calculation
    mapping (address => uint) public lastCollError_Redistribution;
    mapping (address => uint) public lastCUSDDebtError_Redistribution;

    /*
    * --- Variable container structs for liquidations ---
    *
    * These structs are used to hold, return and assign variables inside the liquidation functions,
    * in order to avoid the error: "CompilerError: Stack too deep".
    **/

    // --- Events ---

    event BaseRateUpdated(uint _baseRate);
    event LastFeeOpTimeUpdated(uint _lastFeeOpTime);
    event TotalStakesUpdated(address token, uint _newTotalStakes);
    event SystemSnapshotsUpdated(uint _unix);

    event Liquidation(uint liquidatedAmount, uint totalCUSDGasCompensation,
        address[] totalCollTokens, uint[] totalCollAmounts,
        address[] totalCollGasCompTokens, uint[] totalCollGasCompAmounts);

    event LTermsUpdated(address _Coll_Address, uint _L_Coll, uint _L_CUSDDebt);
    event TroveSnapshotsUpdated(uint _unix);
    event TroveIndexUpdated(address _borrower, uint _newIndex);
    event TroveUpdated(address indexed _borrower, uint _debt, address[] _tokens, uint[] _amounts, TroveManagerOperation operation);

    function setUp() external {
		__Ownable_init();
	}

    function setAddresses(
        address _borrowerOperationsAddress,
        address _activePoolAddress,
        address _defaultPoolAddress,
        address _stabilityPoolAddress,
        address _gasPoolAddress,
        address _collSurplusPoolAddress,
        address _CUSDTokenAddress,
        address _sortedTrovesAddress,
        address _BOCTreasuryAddress,
        address _whitelistAddress,
        address _troveManagerRedemptionsAddress,
        address _troveManagerLiquidationsAddress
    )
    external
    override
    onlyOwner
    {

        borrowerOperationsAddress = _borrowerOperationsAddress;
        activePool = IActivePool(_activePoolAddress);
        defaultPool = IDefaultPool(_defaultPoolAddress);
        stabilityPoolContract = IStabilityPool(_stabilityPoolAddress);
        whitelist = IWhitelist(_whitelistAddress);
        gasPoolAddress = _gasPoolAddress;
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        CUSDTokenContract = ICUSDToken(_CUSDTokenAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        BOCTreasuryContract = ITreasury(_BOCTreasuryAddress);

        troveManagerRedemptionsAddress = _troveManagerRedemptionsAddress;
        troveManagerLiquidationsAddress = _troveManagerLiquidationsAddress;
        troveManagerRedemptions = ITroveManagerRedemptions(_troveManagerRedemptionsAddress);
        troveManagerLiquidations = ITroveManagerLiquidations(_troveManagerLiquidationsAddress);
        renounceOwnership();
    }

    // --- Getters ---

    function getTroveOwnersCount() external view override returns (uint) {
        return TroveOwners.length;
    }

    function getTroveFromTroveOwnersArray(uint _index) external view override returns (address) {
        return TroveOwners[_index];
    }

    // --- Trove Liquidation functions ---

    // Single liquidation function. Closes the trove if its ICR is lower than the minimum collateral ratio.
    function liquidate(address _borrower) external override nonReentrant {
        _requireTroveIsActive(_borrower);

        address[] memory borrowers = new address[](1);
        borrowers[0] = _borrower;
        troveManagerLiquidations.batchLiquidateTroves(borrowers, msg.sender);
    }

    /*
    * Attempt to liquidate a custom list of troves provided by the caller.
    */
    function batchLiquidateTroves(address[] memory _troveArray, address _liquidator) external override nonReentrant {
        troveManagerLiquidations.batchLiquidateTroves(_troveArray, _liquidator);
    }

    // --- Liquidation helper functions ---

    /*
    * This function is called only by TroveManagerLiquidations.sol during a liquidation in recovery mode where
    * the trove has TCR > ICR >= MCR. In this case, the liquidation occurs. 110% of the debt in
    * collateral is sent to the stability pool and any surplus is sent to the collateral surplus pool
    */
    function collSurplusUpdate(address _account, address[] memory _tokens, uint[] memory _amounts) external override {
        _requireCallerIsTML();
        collSurplusPool.accountSurplus(_account, _tokens, _amounts);
    }

    // Move a Trove's pending debt and collateral rewards from distributions, from the Default Pool to the Active Pool
    function movePendingTroveRewardsToActivePool(IActivePool _activePool, IDefaultPool _defaultPool, uint _CUSD, address[] memory _tokens, uint[] memory _amounts, address _borrower) external override {
        _requireCallerIsTML();
        _movePendingTroveRewardsToActivePool(_activePool, _defaultPool, _CUSD, _tokens, _amounts, _borrower);
    }

    function _movePendingTroveRewardsToActivePool(IActivePool _activePool, IDefaultPool _defaultPool, uint _CUSD, address[] memory _tokens, uint[] memory _amounts, address _borrower) internal {
        _defaultPool.decreaseCUSDDebt(_CUSD);
        _activePool.increaseCUSDDebt(_CUSD);
        _defaultPool.sendCollsToActivePool(_tokens, _amounts, _borrower);
    }

    // Update position of given trove
    function _updateTrove(address _borrower, address _lowerHint, address _upperHint) internal {
        (uint debt, address[] memory tokens, uint[] memory amounts, , , ) = getEntireDebtAndColls(_borrower);

        newColls memory troveColl;
        troveColl.tokens = tokens;
        troveColl.amounts = amounts;

        uint RICR = _getRICRColls(troveColl, debt);
        sortedTroves.reInsert(_borrower, RICR, _lowerHint, _upperHint); 
    }

    // Update position for a set of troves using latest price data. This can be called by anyone.
    // Bank of Cronos Loans will also be running a bot to assist with keeping the list from becoming
    // too stale.
    function updateTroves(address[] calldata _borrowers, address[] calldata _lowerHints, address[] calldata _upperHints) external {
        uint lowerHintsLen = _lowerHints.length;
        require(_borrowers.length == lowerHintsLen, "TM: borrowers length mismatch");
        require(lowerHintsLen == _upperHints.length, "TM: hints length mismatch");

        for (uint256 i; i < lowerHintsLen; ++i) {
            _updateTrove(_borrowers[i], _lowerHints[i], _upperHints[i]);
        }
    }

    /* Send _CUSDamount CUSD to the system and redeem the corresponding amount of collateral from as many Troves as are needed to fill the redemption
    * request.  Applies pending rewards to a Trove before reducing its debt and coll.
    *
    * Note that if _amount is very large, this function can run out of gas, specially if traversed troves are small. This can be easily avoided by
    * splitting the total _amount in appropriate chunks and calling the function multiple times.
    *
    * Param `_maxIterations` can also be provided, so the loop through Troves is capped (if it’s zero, it will be ignored).This makes it easier to
    * avoid OOG for the frontend, as only knowing approximately the average cost of an iteration is enough, without needing to know the “topology”
    * of the trove list. It also avoids the need to set the cap in stone in the contract, nor doing gas calculations, as both gas price and opcode
    * costs can vary.
    *
    * All Troves that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be closed.
    * If the last Trove does have some remaining debt, it has a finite ICR, and the reinsertion could be anywhere in the list, therefore it requires a hint.
    * A frontend should use getRedemptionHints() to calculate what the ICR of this Trove will be after redemption, and pass a hint for its position
    * in the sortedTroves list along with the ICR value that the hint was found for.
    *
    * If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
    * is very likely that the last (partially) redeemed Trove would end up with a different ICR than what the hint is for. In this case the
    * redemption will stop after the last completely redeemed Trove and the sender will keep the remaining CUSD amount, which they can attempt
    * to redeem later.
    */
    function redeemCollateral(
        uint _CUSDamount,
        uint _CUSDMaxFee,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint _partialRedemptionHintICR,
        uint _maxIterations
    )
    external
    override
    nonReentrant
    {
        troveManagerRedemptions.redeemCollateral(
            _CUSDamount,
            _CUSDMaxFee,
            _firstRedemptionHint,
            _upperPartialRedemptionHint,
            _lowerPartialRedemptionHint,
            _partialRedemptionHintICR,
            _maxIterations,
            msg.sender);
    }

    // --- Helper functions ---

    // Return the current individual collateral ratio (ICR) of a given Trove.
    // Takes a trove's pending coll and debt rewards from redistributions into account.
    function getCurrentICR(address _borrower) external view override returns (uint ICR) {
        (newColls memory colls, uint currentCUSDDebt) = _getCurrentTroveState(_borrower);

        ICR = _getICRColls(colls, currentCUSDDebt);
    }

    // Return the current recovery individual collateral ratio (ICR) of a given Trove.
    // Takes a trove's pending coll and debt rewards from redistributions into account.
    function getCurrentRICR(address _borrower) external view override returns (uint RICR) {
        (newColls memory colls, uint currentCUSDDebt) = _getCurrentTroveState(_borrower);

        RICR = _getRICRColls(colls, currentCUSDDebt);
    }

    // Gets current trove state as colls and debt. 
    function _getCurrentTroveState(address _borrower) internal view
    returns (newColls memory colls, uint CUSDdebt) {
        newColls memory pendingCollReward = _getPendingCollRewards(_borrower);
        uint pendingCUSDDebtReward = getPendingCUSDDebtReward(_borrower);
        
        CUSDdebt = Troves[_borrower].debt.add(pendingCUSDDebtReward);
        colls = _sumColls(Troves[_borrower].colls, pendingCollReward);
    }

    // Add the borrowers's coll and debt rewards earned from redistributions, to their Trove
    function applyPendingRewards(address _borrower) external override {
        _requireCallerIsBOorTMR();
        return _applyPendingRewards(activePool, defaultPool, _borrower);
    }

    // Add the borrowers's coll and debt rewards earned from redistributions, to their Trove
    function _applyPendingRewards(IActivePool _activePool, IDefaultPool _defaultPool, address _borrower) internal {
        if (hasPendingRewards(_borrower)) {
            _requireTroveIsActive(_borrower);

            // Compute pending collateral rewards
            newColls memory pendingCollReward = _getPendingCollRewards(_borrower);
            uint pendingCUSDDebtReward = getPendingCUSDDebtReward(_borrower);

            // Apply pending rewards to trove's state
            Troves[_borrower].colls = _sumColls(Troves[_borrower].colls, pendingCollReward);
            Troves[_borrower].debt = Troves[_borrower].debt.add(pendingCUSDDebtReward);

            _updateTroveRewardSnapshots(_borrower);

            // Transfer from DefaultPool to ActivePool
            _movePendingTroveRewardsToActivePool(_activePool, _defaultPool, pendingCUSDDebtReward, pendingCollReward.tokens, pendingCollReward.amounts, _borrower);

            emit TroveUpdated(
                _borrower,
                Troves[_borrower].debt,
                Troves[_borrower].colls.tokens,
                Troves[_borrower].colls.amounts,
                TroveManagerOperation.applyPendingRewards
            );
        }
    }

    // Update borrower's snapshots of L_Coll and L_CUSDDebt to reflect the current values
    function updateTroveRewardSnapshots(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        _updateTroveRewardSnapshots(_borrower);
    }

    function _updateTroveRewardSnapshots(address _borrower) internal {
        address[] memory allColls = Troves[_borrower].colls.tokens;
        uint256 allCollsLen = allColls.length;
        for (uint256 i; i < allCollsLen; ++i) {
            address asset = allColls[i];
            rewardSnapshots[_borrower].CollRewards[asset] = L_Coll[asset];
            rewardSnapshots[_borrower].CUSDDebts[asset] = L_CUSDDebt[asset];
        }
        emit TroveSnapshotsUpdated(block.timestamp);
    }

    // Get the borrower's pending accumulated Coll rewards, earned by their stake
    // Returned tokens and amounts are the length of whitelist.getValidCollateral();;
    function getPendingCollRewards(address _borrower) override external view returns (address[] memory, uint[] memory) {
        newColls memory pendingCollRewards = _getPendingCollRewards(_borrower);
        return (pendingCollRewards.tokens, pendingCollRewards.amounts);
    }

    // Get the borrower's pending accumulated Coll rewards, earned by their stake
    function _getPendingCollRewards(address _borrower) internal view returns (newColls memory pendingCollRewards) {
        if (Troves[_borrower].status != Status.active) {
            newColls memory emptyColls;
            return emptyColls;
        }

        address[] memory allColls = Troves[_borrower].colls.tokens;
        pendingCollRewards.amounts = new uint[](allColls.length);
        pendingCollRewards.tokens = allColls;
        uint256 allCollsLen = allColls.length;
        for (uint256 i; i < allCollsLen; ++i) {
            address coll = allColls[i];
            uint snapshotCollReward = rewardSnapshots[_borrower].CollRewards[coll];
            uint rewardPerUnitStaked = L_Coll[coll].sub(snapshotCollReward);
            if ( rewardPerUnitStaked == 0) {
                pendingCollRewards.amounts[i] = 0;
                continue; }

            uint stake = Troves[_borrower].stakes[coll];
            uint dec = IERC20(coll).decimals();
            uint assetCollReward = stake.mul(rewardPerUnitStaked).div(10 ** dec);
            pendingCollRewards.amounts[i] = assetCollReward; // i is correct index here
        }
    }

    // Get the borrower's pending accumulated CUSD reward, earned by their stake
    function getPendingCUSDDebtReward(address _borrower) public view override returns (uint pendingCUSDDebtReward) {
        if (Troves[_borrower].status != Status.active) {
            return 0;
        }
        address[] memory allColls = Troves[_borrower].colls.tokens;

        uint256 allCollsLen = allColls.length;
        for (uint256 i; i < allCollsLen; ++i) {
            address coll = allColls[i];
            uint snapshotCUSDDebt = rewardSnapshots[_borrower].CUSDDebts[coll];
            uint rewardPerUnitStaked = L_CUSDDebt[allColls[i]].sub(snapshotCUSDDebt);
            if ( rewardPerUnitStaked == 0) { continue; }

            uint stake =  Troves[_borrower].stakes[coll];

            uint assetCUSDDebtReward = stake.mul(rewardPerUnitStaked).div(DECIMAL_PRECISION);
            pendingCUSDDebtReward = pendingCUSDDebtReward.add(assetCUSDDebtReward);
        }
    }

    function hasPendingRewards(address _borrower) public view override returns (bool) {
        /*
        * A Trove has pending rewards if its snapshot is less than the current rewards per-unit-staked sum:
        * this indicates that rewards have occured since the snapshot was made, and the user therefore has
        * pending rewards
        */
        if (Troves[_borrower].status != Status.active) {return false;}
        address[] memory assets =  Troves[_borrower].colls.tokens;
        uint256 assetsLen = assets.length;
        for (uint256 i; i < assetsLen; ++i) {
            address token = assets[i];
            if (rewardSnapshots[_borrower].CollRewards[token] < L_Coll[token]) {
                return true;
            }
        }
        return false;
    }

    // Returns debt, collsTokens, collsAmounts, pendingCUSDDebtReward, pendingRewardTokens, pendingRewardAmouns
    function getEntireDebtAndColls(
        address _borrower
    )
    public
    view override
    returns (uint, address[] memory, uint[] memory, uint, address[] memory, uint[] memory)
    {
        uint debt = Troves[_borrower].debt;
        newColls memory colls = Troves[_borrower].colls;

        uint pendingCUSDDebtReward = getPendingCUSDDebtReward(_borrower);
        newColls memory pendingCollReward = _getPendingCollRewards(_borrower);

        debt = debt.add(pendingCUSDDebtReward);

        // add in pending rewards to colls
        colls = _sumColls(colls, pendingCollReward);

        return (debt, colls.tokens, colls.amounts, pendingCUSDDebtReward, pendingCollReward.tokens, pendingCollReward.amounts);
    }

    // Borrower operations remove stake sum. 
    function removeStake(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _removeStake(_borrower);
    }

    // Remove borrower's stake from the totalStakes sum, and set their stake to 0
    function _removeStake(address _borrower) internal {
        address[] memory borrowerColls = Troves[_borrower].colls.tokens;
        uint256 borrowerCollsLen = borrowerColls.length;
        for (uint256 i; i < borrowerCollsLen; ++i) {
            address coll = borrowerColls[i];
            uint stake = Troves[_borrower].stakes[coll];
            totalStakes[coll] = totalStakes[coll].sub(stake);
            Troves[_borrower].stakes[coll] = 0;
        }
    }

    // Update borrower's stake based on their latest collateral value
    // computed at time function is called based on current price of collateral
    function updateStakeAndTotalStakes(address _borrower) external override {
        _requireCallerIsBOorTMR();
        _updateStakeAndTotalStakes(_borrower);
    }

    function _updateStakeAndTotalStakes(address _borrower) internal {
        uint256 troveOwnerLen = Troves[_borrower].colls.tokens.length;
        for (uint256 i; i < troveOwnerLen; ++i) {
            address token = Troves[_borrower].colls.tokens[i];
            uint amount = Troves[_borrower].colls.amounts[i];

            uint newStake = _computeNewStake(token, amount);
            uint oldStake = Troves[_borrower].stakes[token];

            Troves[_borrower].stakes[token] = newStake;
            totalStakes[token] = totalStakes[token].sub(oldStake).add(newStake);

            emit TotalStakesUpdated(token, totalStakes[token]);
        }
    }

    // Calculate a new stake based on the snapshots of the totalStakes and totalCollateral taken at the last liquidation
    function _computeNewStake(address token, uint _coll) internal view returns (uint) {
        uint stake;
        if (totalCollateralSnapshot[token] == 0) {
            stake = _coll;
        } else {
            /*
            * The following assert() holds true because:
            * - The system always contains >= 1 trove
            * - When we close or liquidate a trove, we redistribute the pending rewards, so if all troves were closed/liquidated,
            * rewards would’ve been emptied and totalCollateralSnapshot would be zero too.
            */
            require(totalStakesSnapshot[token] != 0, "TM: stake !> 0");
            stake = _coll.mul(totalStakesSnapshot[token]).div(totalCollateralSnapshot[token]);
        }
        return stake;
    }

    function redistributeDebtAndColl(IActivePool _activePool, IDefaultPool _defaultPool, uint _debt, address[] memory _tokens, uint[] memory _amounts) external override {
        _requireCallerIsTML();
        uint256 tokensLen = _tokens.length;
        require(tokensLen == _amounts.length, "TM: len");
        if (_debt == 0) { return; }
        /*
        * Add distributed coll and debt rewards-per-unit-staked to the running totals. Division uses a "feedback"
        * error correction, to keep the cumulative error low in the running totals L_Coll and L_CUSDDebt:
        *
        * 1) Form numerators which compensate for the floor division errors that occurred the last time this
        * function was called.
        * 2) Calculate "per-unit-staked" ratios.
        * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
        * 4) Store these errors for use in the next correction when this function is called.
        * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
        */
        uint totalCollateralVC = _getVC(_tokens, _amounts); // total collateral value in VC terms

        for (uint256 i; i < tokensLen; ++i) {
            address token = _tokens[i];
            uint amount = _amounts[i];
            // Prorate debt per collateral by dividing each collateral value by cumulative collateral value and multiply by outstanding debt
            uint collateralVC = whitelist.getValueVC(token, amount);
            uint proratedDebtForCollateral = collateralVC.mul(_debt).div(totalCollateralVC);
            uint dec = IERC20(token).decimals();
            uint CollNumerator = amount.mul(10 ** dec).add(lastCollError_Redistribution[token]);
            uint CUSDDebtNumerator = proratedDebtForCollateral.mul(DECIMAL_PRECISION).add(lastCUSDDebtError_Redistribution[token]);
            if (totalStakes[token] != 0) {
                // Get the per-unit-staked terms
                uint256 thisTotalStakes = totalStakes[token];
                uint CollRewardPerUnitStaked = CollNumerator.div(thisTotalStakes);
                uint CUSDDebtRewardPerUnitStaked = CUSDDebtNumerator.div(thisTotalStakes.mul(10 ** (18 - dec)));

                lastCollError_Redistribution[token] = CollNumerator.sub(CollRewardPerUnitStaked.mul(thisTotalStakes));
                lastCUSDDebtError_Redistribution[token] = CUSDDebtNumerator.sub(CUSDDebtRewardPerUnitStaked.mul(thisTotalStakes.mul(10 ** (18 - dec))));

                // Add per-unit-staked terms to the running totals
                L_Coll[token] = L_Coll[token].add(CollRewardPerUnitStaked);
                L_CUSDDebt[token] = L_CUSDDebt[token].add(CUSDDebtRewardPerUnitStaked);
                emit LTermsUpdated(token, L_Coll[token], L_CUSDDebt[token]);
            }
        }

        // Transfer coll and debt from ActivePool to DefaultPool
        _activePool.decreaseCUSDDebt(_debt);
        _defaultPool.increaseCUSDDebt(_debt);
        _activePool.sendCollaterals(address(_defaultPool), _tokens, _amounts);
    }

    function closeTrove(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _closeTrove(_borrower, Status.closedByOwner);
    }

    function closeTroveLiquidation(address _borrower) external override {
        _requireCallerIsTML();
        return _closeTrove(_borrower, Status.closedByLiquidation);
    }

    function closeTroveRedemption(address _borrower) external override {
        _requireCallerIsTMR();
        return _closeTrove(_borrower, Status.closedByRedemption);
    }

    function _closeTrove(address _borrower, Status closedStatus) internal {
        require(closedStatus != Status.nonExistent && closedStatus != Status.active, "Status !active|!exists");

        uint TroveOwnersArrayLength = TroveOwners.length;
        _requireMoreThanOneTroveInSystem(TroveOwnersArrayLength);
        newColls memory emptyColls;


        address[] memory allColls = Troves[_borrower].colls.tokens;        
        uint allCollsLen = allColls.length;
        for (uint256 i; i < allCollsLen; ++i) {
            address thisAllColls = allColls[i];
            rewardSnapshots[_borrower].CollRewards[thisAllColls] = 0;
            rewardSnapshots[_borrower].CUSDDebts[thisAllColls] = 0;
        }

        Troves[_borrower].status = closedStatus;
        Troves[_borrower].colls = emptyColls;
        Troves[_borrower].debt = 0;

        _removeTroveOwner(_borrower, TroveOwnersArrayLength);
        sortedTroves.remove(_borrower);
    }

    /*
    * Updates snapshots of system total stakes and total collateral, excluding a given collateral remainder from the calculation.
    * Used in a liquidation sequence.
    *
    * The calculation excludes a portion of collateral that is in the ActivePool:
    *
    * the total Coll gas compensation from the liquidation sequence
    *
    * The Coll as compensation must be excluded as it is always sent out at the very end of the liquidation sequence.
    */
    function updateSystemSnapshots_excludeCollRemainder(IActivePool _activePool, address[] memory _tokens, uint[] memory _amounts) external override {
        _requireCallerIsTML();
        uint256 tokensLen = _tokens.length;
        for (uint256 i; i < tokensLen; ++i) {
            address token = _tokens[i];
            totalStakesSnapshot[token] = totalStakes[token];

            uint _tokenRemainder = _amounts[i];
            uint activeColl = _activePool.getCollateral(token);
            uint liquidatedColl = defaultPool.getCollateral(token);
            totalCollateralSnapshot[token] = activeColl.sub(_tokenRemainder).add(liquidatedColl);
        }
        emit SystemSnapshotsUpdated(block.timestamp);
    }

    // Push the owner's address to the Trove owners list, and record the corresponding array index on the Trove struct
    function addTroveOwnerToArray(address _borrower) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        return _addTroveOwnerToArray(_borrower);
    }

    function _addTroveOwnerToArray(address _borrower) internal returns (uint128 index) {
        /* Max array size is 2**128 - 1, i.e. ~3e30 troves. No risk of overflow, since troves have minimum CUSD
        debt of liquidation reserve plus MIN_NET_DEBT. 3e30 CUSD dwarfs the value of all wealth in the world ( which is < 1e15 USD). */
        // Push the Troveowner to the array
        TroveOwners.push(_borrower);

        // Record the index of the new Troveowner on their Trove struct
        index = uint128(TroveOwners.length.sub(1));
        Troves[_borrower].arrayIndex = index;
    }

    /*
    * Remove a Trove owner from the TroveOwners array, not preserving array order. Removing owner 'B' does the following:
    * [A B C D E] => [A E C D], and updates E's Trove struct to point to its new array index.
    */
    function _removeTroveOwner(address _borrower, uint TroveOwnersArrayLength) internal {
        Status troveStatus = Troves[_borrower].status;
        // It’s set in caller function `_closeTrove`
        require(troveStatus != Status.nonExistent && troveStatus != Status.active, "TM: trove !ext|!act");

        uint128 index = Troves[_borrower].arrayIndex;
        uint length = TroveOwnersArrayLength;
        uint idxLast = length.sub(1);

        require(index <= idxLast, "TM: index!>lst ind");

        address addressToMove = TroveOwners[idxLast];

        TroveOwners[index] = addressToMove;
        Troves[addressToMove].arrayIndex = index;
        emit TroveIndexUpdated(addressToMove, index);

        TroveOwners.pop();
    }

    // --- Recovery Mode and TCR functions ---

    function getTCR() external view override returns (uint) {
        return _getTCR();
    }

    function checkRecoveryMode() external view override returns (bool) {
        return _checkRecoveryMode();
    }


    // --- Redemption fee functions ---

    function updateBaseRate(uint newBaseRate) external override {
        _requireCallerIsTMR();
        require(newBaseRate != 0, "TM: newBR!>0");
        baseRate = newBaseRate;
        emit BaseRateUpdated(newBaseRate);
        _updateLastFeeOpTime();
    }

    function getRedemptionRate() public view override returns (uint) {
        return _calcRedemptionRate(baseRate);
    }

    function getRedemptionRateWithDecay() public view override returns (uint) {
        return _calcRedemptionRate(calcDecayedBaseRate());
    }

    function _calcRedemptionRate(uint _baseRate) internal pure returns (uint) {
        return LiquityMath._min(
            REDEMPTION_FEE_FLOOR.add(_baseRate),
            DECIMAL_PRECISION // cap at a maximum of 100%
        );
    }

    function _getRedemptionFee(uint _CUSDRedeemed) internal view returns (uint) {
        return _calcRedemptionFee(getRedemptionRate(), _CUSDRedeemed);
    }

    function getRedemptionFeeWithDecay(uint _CUSDRedeemed) external view override returns (uint) {
        return _calcRedemptionFee(getRedemptionRateWithDecay(), _CUSDRedeemed);
    }

    function _calcRedemptionFee(uint _redemptionRate, uint _CUSDRedeemed) internal pure returns (uint) {
        uint redemptionFee = _redemptionRate.mul(_CUSDRedeemed).div(DECIMAL_PRECISION);
        require(redemptionFee < _CUSDRedeemed, "TM:Fee>ret colls");
        return redemptionFee;
    }


    // --- Borrowing fee functions ---

    function getBorrowingRate() public view override returns (uint) {
        return _calcBorrowingRate(baseRate);
    }

    function getBorrowingRateWithDecay() public view override returns (uint) {
        return _calcBorrowingRate(calcDecayedBaseRate());
    }

    function _calcBorrowingRate(uint _baseRate) internal pure returns (uint) {
        return LiquityMath._min(
            BORROWING_FEE_FLOOR.add(_baseRate),
            MAX_BORROWING_FEE
        );
    }

    function getBorrowingFee(uint _CUSDDebt) external view override returns (uint) {
        return _calcBorrowingFee(getBorrowingRate(), _CUSDDebt);
    }

    function getBorrowingFeeWithDecay(uint _CUSDDebt) external view override returns (uint) {
        return _calcBorrowingFee(getBorrowingRateWithDecay(), _CUSDDebt);
    }

    function _calcBorrowingFee(uint _borrowingRate, uint _CUSDDebt) internal pure returns (uint) {
        return _borrowingRate.mul(_CUSDDebt).div(DECIMAL_PRECISION);
    }


    // Updates the baseRate state variable based on time elapsed since the last redemption or CUSD borrowing operation.
    function decayBaseRateFromBorrowing() external override {
        _requireCallerIsBorrowerOperations();

        uint decayedBaseRate = calcDecayedBaseRate();
        require(decayedBaseRate <= DECIMAL_PRECISION, "TM: decBR<");  // The baseRate can decay to 0

        baseRate = decayedBaseRate;
        emit BaseRateUpdated(decayedBaseRate);

        _updateLastFeeOpTime();
    }


    // --- Internal fee functions ---

    // Update the last fee operation time only if time passed >= decay interval. This prevents base rate griefing.
    function _updateLastFeeOpTime() internal {
        uint timePassed = block.timestamp.sub(lastFeeOperationTime);

        if (timePassed >= SECONDS_IN_ONE_MINUTE) {
            lastFeeOperationTime = block.timestamp;
            emit LastFeeOpTimeUpdated(block.timestamp);
        }
    }

    function calcDecayedBaseRate() public view override returns (uint) {
        uint minutesPassed = _minutesPassedSinceLastFeeOp();
        uint decayFactor = LiquityMath._decPow(MINUTE_DECAY_FACTOR, minutesPassed);

        return baseRate.mul(decayFactor).div(DECIMAL_PRECISION);
    }

    function _minutesPassedSinceLastFeeOp() internal view returns (uint) {
        return (block.timestamp.sub(lastFeeOperationTime)).div(SECONDS_IN_ONE_MINUTE);
    }

    // --- 'require' wrapper functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        if (msg.sender != borrowerOperationsAddress) {
            _revertWrongFuncCaller();
        }
    }

    function _requireCallerIsBOorTMR() internal view {
        if (msg.sender != borrowerOperationsAddress && msg.sender != troveManagerRedemptionsAddress) {
            _revertWrongFuncCaller();
        }
    }

    function _requireCallerIsTMR() internal view {
        if (msg.sender != troveManagerRedemptionsAddress) {
            _revertWrongFuncCaller();
        }
    }

    function _requireCallerIsTML() internal view {
        if (msg.sender != troveManagerLiquidationsAddress) {
            _revertWrongFuncCaller();
        }
    }

    function _revertWrongFuncCaller() internal pure {
        revert("TM: Ext.call");
    }

    function _requireTroveIsActive(address _borrower) internal view {
        require(Troves[_borrower].status == Status.active, "TM: tmust exist");
    }

    function _requireMoreThanOneTroveInSystem(uint TroveOwnersArrayLength) internal view {
        require (TroveOwnersArrayLength > 1 && sortedTroves.getSize() > 1, "TM: last trove");
    }

    // --- Trove property getters ---

    function getTroveStatus(address _borrower) external view override returns (uint) {
        return uint(Troves[_borrower].status);
    }

    function isTroveActive(address _borrower) external view override returns (bool) {
        return Troves[_borrower].status == Status.active;
    }

    function getTroveStake(address _borrower, address _token) external view override returns (uint) {
        return Troves[_borrower].stakes[_token];
    }

    function getTroveDebt(address _borrower) external view override returns (uint) {
        return Troves[_borrower].debt;
    }

    // -- Trove Manager State Variable Getters -- 

    function getTotalStake(address _token) external view override returns (uint) {
        return totalStakes[_token];
    }

    function getL_Coll(address _token) external view override returns (uint) {
        return L_Coll[_token];
    }

    function getL_CUSD(address _token) external view override returns (uint) {
        return L_CUSDDebt[_token];
    }

    function getRewardSnapshotColl(address _borrower, address _token) external view override returns (uint) {
        return rewardSnapshots[_borrower].CollRewards[_token];
    }

    function getRewardSnapshotCUSD(address _borrower, address _token) external view override returns (uint) {
        return rewardSnapshots[_borrower].CUSDDebts[_token];
    }

    // recomputes VC given current prices and returns it
    function getTroveVC(address _borrower) external view override returns (uint) {
        return _getVCColls(Troves[_borrower].colls);
    }

    function getTroveColls(address _borrower) external view override returns (address[] memory, uint[] memory) {
        return (Troves[_borrower].colls.tokens, Troves[_borrower].colls.amounts);
    }

    function getCurrentTroveState(address _borrower) external override view returns (address[] memory, uint[] memory, uint) {
        (newColls memory colls, uint currentCUSDDebt) = _getCurrentTroveState(_borrower);
        return (colls.tokens, colls.amounts, currentCUSDDebt);
    }

    // --- Called by TroveManagerRedemptions Only ---


    function updateTroveDebt(address _borrower, uint debt) external override {
        _requireCallerIsTMR();
        Troves[_borrower].debt = debt;
    }

    function updateTroveCollTMR(address  _borrower, address[] memory addresses, uint[] memory amounts) external override {
        _requireCallerIsTMR();
        (Troves[_borrower].colls.tokens, Troves[_borrower].colls.amounts) = (addresses, amounts);
    }

    function removeStakeTMR(address _borrower) external override {
        _requireCallerIsTMR();
        _removeStake(_borrower);
    }

    // --- Called by TroverManagerLiquidations Only ---

    function removeStakeTLR(address _borrower) external override {
        _requireCallerIsTML();
        _removeStake(_borrower);
    }

    // --- Trove property setters, called by BorrowerOperations ---

    function setTroveStatus(address _borrower, uint _num) external override {
        _requireCallerIsBorrowerOperations();
        Troves[_borrower].status = Status(_num);
    }

    function updateTroveColl(address _borrower, address[] memory _tokens, uint[] memory _amounts) external override {
        _requireCallerIsBorrowerOperations();
        require(_tokens.length == _amounts.length, "TM: len mismatch");
        Troves[_borrower].colls.tokens = _tokens;
        Troves[_borrower].colls.amounts = _amounts;
    }

    function increaseTroveDebt(address _borrower, uint _debtIncrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newDebt = Troves[_borrower].debt.add(_debtIncrease);
        Troves[_borrower].debt = newDebt;
        return newDebt;
    }

    function decreaseTroveDebt(address _borrower, uint _debtDecrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newDebt = Troves[_borrower].debt.sub(_debtDecrease);
        Troves[_borrower].debt = newDebt;
        return newDebt;
    }

    // --- contract getters ---

    function stabilityPool() external view override returns (IStabilityPool) {
        return stabilityPoolContract;
    }

    function CUSDToken() external view override returns (ICUSDToken) {
        return CUSDTokenContract;
    }

    function BOCTreasury() external view override returns (ITreasury) {
        return BOCTreasuryContract;
    }
 }