// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "./Interfaces/IWAsset.sol";
import "./Dependencies/TroveManagerBase.sol";
import "./Dependencies/SafeERC20.sol";

/** 
 * TroveManagerRedemptions is derived from TroveManager and handles all redemption activity of troves. 
 * Instead of calculating redemption fees in ETH like Liquity used to, we now calculate it as a portion 
 * of CUSD passed in to redeem. The CUSDAmount is still how much we would like to redeem, but the
 * CUSDFee is now the maximum amount of CUSD extra that will be paid and must be in the balance of the
 * redeemer for the redemption to succeed. This fee is the same as before in terms of percentage of value, 
 * but now it is in terms of CUSD. We now use a helper function to be able to estimate how much CUSD will
 * be actually needed to perform a redemption of a certain amount, and also given an amount of CUSD balance,
 * the max amount of CUSD that can be used for a redemption, and a max fee such that it will always go through.
 * 
 * Given a balance of CUSD, Z, the amount that can actually be redeemed is :
 * Y = CUSD you can actually redeem
 * BR = decayed base rate 
 * X = CUSD Fee
 * S = Total CUSD Supply
 * The redemption fee rate is = (Y / S * 1 / BETA + BR + 0.5%)
 * This is because the new base rate = BR + Y / S * 1 / BETA
 * We pass in X + Y = Z, and want to find X and Y. 
 * Y is calculated to be = S * (sqrt((1.005 + BR)**2 + BETA * Z / S) - 1.005 - BR)
 * through the quadratic formula, and X = Z - Y. 
 * Therefore the amount we can actually redeem given Z is Y, and the max fee is X. 
 * 
 * To find how much the fee is given Y, we can multiply Y by the new base rate, which is BR + Y / S * 1 / BETA. 
 * 
 * To the redemption function, we pass in Y and X. 
 */

contract TroveManagerRedemptions is TroveManagerBase, ITroveManagerRedemptions {
    bytes32 constant public NAME = "TroveManagerRedemptions";

    using SafeERC20 for ICUSDToken;


    address internal borrowerOperationsAddress;

    IStabilityPool internal stabilityPoolContract;

    ITroveManager internal troveManager;

    ICUSDToken internal CUSDTokenContract;

    address internal BOCTreasuryContract;

    ITroveManagerRedemptions internal troveManagerRedemptions;

    address internal gasPoolAddress;

    ISortedTroves internal sortedTroves;

    ICollSurplusPool internal collSurplusPool;

    struct RedemptionTotals {
        uint256 remainingCUSD;
        uint256 totalCUSDToRedeem;
        newColls CollsDrawn;
        uint256 CUSDfee;
        uint256 decayedBaseRate;
        uint256 totalCUSDSupplyAtStart;
        uint256 maxCUSDFeeAmount;
    }
    struct Hints {
        address upper;
        address lower;
        address target;
        uint256 ricr;
    }

    /*
     * BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
     * Corresponds to (1 / ALPHA) in the white paper.
     */
    uint256 public constant BETA = 2;

    uint256 public constant BOOTSTRAP_PERIOD = 14 days;

    event Redemption(
        uint256 _attemptedCUSDAmount,
        uint256 _actualCUSDAmount,
        uint256 CUSDfee,
        address[] tokens,
        uint256[] amounts
    );

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
        address _troveManagerAddress
    ) external onlyOwner {

        borrowerOperationsAddress = _borrowerOperationsAddress;
        activePool = IActivePool(_activePoolAddress);
        defaultPool = IDefaultPool(_defaultPoolAddress);
        stabilityPoolContract = IStabilityPool(_stabilityPoolAddress);
        whitelist = IWhitelist(_whitelistAddress);
        gasPoolAddress = _gasPoolAddress;
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        CUSDTokenContract = ICUSDToken(_CUSDTokenAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        BOCTreasuryContract = _BOCTreasuryAddress;
        troveManager = ITroveManager(_troveManagerAddress);

        renounceOwnership();
    }

    /** 
     * Main function for redeeming collateral. See above for how CUSDMaxFee is calculated.
     * @param _CUSDamount is equal to the amount of CUSD to actually redeem.
     * @param _CUSDMaxFee is equal to the max fee in CUSD that the sender is willing to pay
     * _CUSDamount + _CUSDMaxFee must be less than the balance of the sender.
     */
    function redeemCollateral(
        uint256 _CUSDamount,
        uint256 _CUSDMaxFee,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintICR,
        uint256 _maxIterations,
        address _redeemer
    ) external override {
        _requireCallerisTroveManager();
        ContractsCache memory contractsCache = ContractsCache(
            activePool,
            defaultPool,
            CUSDTokenContract,
            BOCTreasuryContract,
            sortedTroves,
            collSurplusPool,
            gasPoolAddress
        );
        RedemptionTotals memory totals;

        _requireValidMaxFee(_CUSDamount, _CUSDMaxFee);
        //_requireAfterBootstrapPeriod();
        _requireTCRoverMCR();
        _requireAmountGreaterThanZero(_CUSDamount);

        totals.totalCUSDSupplyAtStart = getEntireSystemDebt();

        // Confirm redeemer's balance is less than total CUSD supply
        require(contractsCache.CUSDToken.balanceOf(_redeemer) <= totals.totalCUSDSupplyAtStart, "TMR: redeemer balance too high");

        totals.remainingCUSD = _CUSDamount;
        address currentBorrower;
        if (_isValidFirstRedemptionHint(contractsCache.sortedTroves, _firstRedemptionHint)) {
            currentBorrower = _firstRedemptionHint;
        } else {
            currentBorrower = contractsCache.sortedTroves.getLast();
            // Find the first trove with ICR >= MCR
            while (
                currentBorrower != address(0) && troveManager.getCurrentRICR(currentBorrower) < MCR 
            ) {
                currentBorrower = contractsCache.sortedTroves.getPrev(currentBorrower);
            }
        }
        // Loop through the Troves starting from the one with lowest collateral ratio until _amount of CUSD is exchanged for collateral
        if (_maxIterations == 0) {
            _maxIterations = uint256(-1);
        }
        while (currentBorrower != address(0) && totals.remainingCUSD != 0 && _maxIterations != 0) {
            _maxIterations--;
            // Save the address of the Trove preceding the current one, before potentially modifying the list
            address nextUserToCheck = contractsCache.sortedTroves.getPrev(currentBorrower);

            if (troveManager.getCurrentRICR(currentBorrower) >= MCR) { 
                troveManager.applyPendingRewards(currentBorrower);

                SingleRedemptionValues memory singleRedemption = _redeemCollateralFromTrove(
                    contractsCache,
                    currentBorrower,
                    totals.remainingCUSD,
                    _upperPartialRedemptionHint,
                    _lowerPartialRedemptionHint,
                    _partialRedemptionHintICR
                );

                if (singleRedemption.cancelledPartial) break; // Partial redemption was cancelled (out-of-date hint, or new net debt < minimum), therefore we could not redeem from the last Trove

                totals.totalCUSDToRedeem = totals.totalCUSDToRedeem.add(singleRedemption.CUSDLot);

                totals.CollsDrawn = _sumColls(totals.CollsDrawn, singleRedemption.CollLot);
                totals.remainingCUSD = totals.remainingCUSD.sub(singleRedemption.CUSDLot);
            }

            currentBorrower = nextUserToCheck;
        }

        require(isNonzero(totals.CollsDrawn), "TMR:noCollsDrawn");
        // Decay the baseRate due to time passed, and then increase it according to the size of this redemption.
        // Use the saved total CUSD supply value, from before it was reduced by the redemption.
        _updateBaseRateFromRedemption(totals.totalCUSDToRedeem, totals.totalCUSDSupplyAtStart);

        totals.CUSDfee = _getRedemptionFee(totals.totalCUSDToRedeem);
        // check user has enough CUSD to pay fee and redemptions
        _requireCUSDBalanceCoversRedemption(
            contractsCache.CUSDToken,
            _redeemer,
            _CUSDamount.add(totals.CUSDfee)
        );

        // check to see that the fee doesn't exceed the max fee
        _requireUserAcceptsFeeRedemption(totals.CUSDfee, _CUSDMaxFee);

        // send fee from user to Bank of Cronos Treasury
        contractsCache.CUSDToken.safeTransferFrom(
            _redeemer,
            address(contractsCache.BOCTreasury),
            totals.CUSDfee
        );

        emit Redemption(
            _CUSDamount,
            totals.totalCUSDToRedeem,
            totals.CUSDfee,
            totals.CollsDrawn.tokens,
            totals.CollsDrawn.amounts
        );
        // Burn the total CUSD that is cancelled with debt
        contractsCache.CUSDToken.burn(_redeemer, totals.totalCUSDToRedeem);
        // Update Active Pool CUSD, and send Collaterals to account
        contractsCache.activePool.decreaseCUSDDebt(totals.totalCUSDToRedeem);

        contractsCache.activePool.sendCollateralsUnwrap(
            address(this), // This contract accumulates rewards for all the wrapped assets short term.
            _redeemer,
            totals.CollsDrawn.tokens,
            totals.CollsDrawn.amounts
        );
    }

    /** 
     * Secondary function for redeeming collateral. See above for how CUSDMaxFee is calculated.
     * @param _CUSDamount is equal to the amount of CUSD to actually redeem.
     * @param _CUSDMaxFee is equal to the max fee in CUSD that the sender is willing to pay
     * _CUSDamount + _CUSDMaxFee must be less than the balance of the sender.
     */
    function redeemCollateralSingle(
        uint256 _CUSDamount,
        uint256 _CUSDMaxFee,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintRICR,
        address _collToRedeem
    ) external {
        // _requireCallerisTroveManager(); todo 
        ContractsCache memory contractsCache = ContractsCache(
            activePool,
            defaultPool,
            CUSDTokenContract,
            BOCTreasuryContract,
            sortedTroves,
            collSurplusPool,
            gasPoolAddress
        );
        RedemptionTotals memory totals;
        Hints memory hints;

        hints.target = _firstRedemptionHint;
        hints.ricr = _partialRedemptionHintRICR; 
        hints.upper = _upperPartialRedemptionHint;
        hints.lower = _lowerPartialRedemptionHint;
        
        _requireValidMaxFee(_CUSDamount, _CUSDMaxFee);
        //_requireAfterBootstrapPeriod();
        _requireTCRoverMCR(); // todo recalculates system debt, could save a calculation
        _requireAmountGreaterThanZero(_CUSDamount);
        // address _redeemer = msg.sender;
        totals.totalCUSDSupplyAtStart = getEntireSystemDebt();

        // Confirm redeemer's balance is less than total CUSD supply
        require(contractsCache.CUSDToken.balanceOf(msg.sender) <= totals.totalCUSDSupplyAtStart, "TMR:Redeemer CUSD Bal too high");

        totals.remainingCUSD = _CUSDamount;
        require(_isValidFirstRedemptionHint(contractsCache.sortedTroves, hints.target), "TMR:Invalid first redemption hint");
        troveManager.applyPendingRewards(hints.target);

        // Stitched in _redeemCollateralFromTrove
        /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        SingleRedemptionValues memory singleRedemption;
        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the Trove minus the liquidation reserve
        uint troveDebt = troveManager.getTroveDebt(hints.target);
        singleRedemption.CUSDLot = LiquityMath._min(
            totals.remainingCUSD,
            troveDebt.sub(CUSD_GAS_COMPENSATION)
        );

        newColls memory colls;
        (colls.tokens, colls.amounts, ) = troveManager.getCurrentTroveState(hints.target);

        uint256 i; // i term will be used as the index of the collateral to redeem later too
        uint256 tokensLen = colls.tokens.length;
        {//Limit scope
            //Make sure single collateral to redeem exists in trove
            bool foundCollateral;
            
            for (i = 0; i < tokensLen; ++i) {
                if (colls.tokens[i] == _collToRedeem) {
                    foundCollateral = true;
                    break;
                }
            }
            require(foundCollateral, "TMR:Coll not in trove");
        }

        {// Limit scope
            uint256 singleCollUSD = whitelist.getValueUSD(_collToRedeem, colls.amounts[i]); //Get usd value of only the collateral being redeemed
            
            //Cap redemption amount to the max amount of collateral that can be redeemed
            singleRedemption.CUSDLot = LiquityMath._min(
                singleCollUSD,
                singleRedemption.CUSDLot
            );
            

            // redemption addresses are the same as coll addresses for trove
            // Calculation for how much collateral to send of each type. 
            singleRedemption.CollLot.tokens = colls.tokens;
            singleRedemption.CollLot.amounts = new uint256[](tokensLen);
            
            uint tokenAmountToRedeem = singleRedemption.CUSDLot.mul(colls.amounts[i]).div(singleCollUSD);
            colls.amounts[i] = colls.amounts[i].sub(tokenAmountToRedeem);
            singleRedemption.CollLot.amounts[i] = tokenAmountToRedeem;
        }

        
        // Decrease the debt and collateral of the current Trove according to the CUSD lot and corresponding Collateral to send
        troveDebt = troveDebt.sub(singleRedemption.CUSDLot);
        

        if (troveDebt == CUSD_GAS_COMPENSATION) {
            // No debt left in the Trove (except for the liquidation reserve), therefore the trove gets closed
            troveManager.removeStakeTMR(hints.target);
            troveManager.closeTroveRedemption(hints.target);
            _redeemCloseTrove(
                contractsCache,
                hints.target,
                CUSD_GAS_COMPENSATION,
                colls.tokens,
                colls.amounts
            );

            address[] memory emptyTokens = new address[](0);
            uint256[] memory emptyAmounts = new uint256[](0);

            emit TroveUpdated(
                hints.target,
                0,
                emptyTokens,
                emptyAmounts,
                TroveManagerOperation.redeemCollateral
            );
        } else {
            
            uint256 newRICR = _getRICRColls(colls, troveDebt); 

            /*
            * If the provided hint is too inaccurate of date, we bail since trying to reinsert without a good hint will almost
            * certainly result in running out of gas. Arbitrary measures of this mean newRICR must be greater than hint RICR - 2%, 
            * and smaller than hint ICR + 2%.
            *
            * If the resultant net debt of the partial is less than the minimum, net debt we bail.
            */
            {//Stack scope
                if (newRICR >= hints.ricr.add(2e16) ||
                    newRICR <= hints.ricr.sub(2e16) || 
                    _getNetDebt(troveDebt) < MIN_NET_DEBT) {
                    revert("Invalid partial redemption hint or remaining debt is too low");
                    // singleRedemption.cancelledPartial = true;
                    // return singleRedemption;
                }
            
                contractsCache.sortedTroves.reInsert(
                    hints.target,
                    newRICR, 
                    hints.upper,
                    hints.lower
                );
            }
            troveManager.updateTroveDebt(hints.target, troveDebt);
            // for (uint256 k = 0; k < colls.tokens.length; k++) {
            //     colls.amounts[k] = finalAmounts[k];
            // }
            troveManager.updateTroveCollTMR(hints.target, colls.tokens, colls.amounts);
            troveManager.updateStakeAndTotalStakes(hints.target);

            emit TroveUpdated(
                hints.target,
                troveDebt,
                colls.tokens,
                colls.amounts,
                TroveManagerOperation.redeemCollateral
            );
        }
    
        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////


        totals.totalCUSDToRedeem = singleRedemption.CUSDLot;

        totals.CollsDrawn = singleRedemption.CollLot;
        // totals.remainingCUSD = totals.remainingCUSD.sub(singleRedemption.CUSDLot);

        require(isNonzero(totals.CollsDrawn), "TMR: non zero collsDrawn");
        // Decay the baseRate due to time passed, and then increase it according to the size of this redemption.
        // Use the saved total CUSD supply value, from before it was reduced by the redemption.
        _updateBaseRateFromRedemption(totals.totalCUSDToRedeem, totals.totalCUSDSupplyAtStart);

        totals.CUSDfee = _getRedemptionFee(totals.totalCUSDToRedeem);
        // check user has enough CUSD to pay fee and redemptions
        _requireCUSDBalanceCoversRedemption(
            contractsCache.CUSDToken,
            msg.sender,
            totals.remainingCUSD.add(totals.CUSDfee)
        );

        // check to see that the fee doesn't exceed the max fee
        _requireUserAcceptsFeeRedemption(totals.CUSDfee, _CUSDMaxFee);

        // send fee from user to Bank of Cronos Treasury
        contractsCache.CUSDToken.safeTransferFrom( // todo
            msg.sender,
            address(contractsCache.BOCTreasury),
            totals.CUSDfee
        );

        emit Redemption(
            totals.remainingCUSD,
            totals.totalCUSDToRedeem,
            totals.CUSDfee,
            totals.CollsDrawn.tokens,
            totals.CollsDrawn.amounts
        );
        // Burn the total CUSD that is cancelled with debt
        contractsCache.CUSDToken.burn(msg.sender, totals.totalCUSDToRedeem);
        // Update Active Pool CUSD, and send Collaterals to account
        contractsCache.activePool.decreaseCUSDDebt(totals.totalCUSDToRedeem);

        contractsCache.activePool.sendCollateralsUnwrap(
            hints.target, // rewards from
            msg.sender, // tokens to
            totals.CollsDrawn.tokens,
            totals.CollsDrawn.amounts
        );
    }

    /** 
     * Redeem as much collateral as possible from _borrower's Trove in exchange for CUSD up to _maxCUSDamount
     * Special calculation for determining how much collateral to send of each type to send. 
     * We want to redeem equivalent to the USD value instead of the VC value here, so we take the CUSD amount
     * which we are redeeming from this trove, and calculate the ratios at which we would redeem a single 
     * collateral type compared to all others. 
     * For example if we are redeeming 10,000 from this trove, and it has collateral A with a safety ratio of 1, 
     * collateral B with safety ratio of 0.5. Let's say their price is each 1. The trove is composed of 10,000 A and 
     * 10,000 B, so we would redeem 5,000 A and 5,000 B, instead of 6,666 A and 3,333 B. To do calculate this we take 
     * the USD value of that collateral type, and divide it by the total USD value of all collateral types. The price 
     * actually cancels out here so we just do CUSD amount * token amount / total USD value, instead of
     * CUSD amount * token value / total USD value / token price, since we are trying to find token amount.
     */
    function _redeemCollateralFromTrove(
        ContractsCache memory _contractsCache,
        address _borrower,
        uint256 _maxCUSDAmount,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintRICR
    ) internal returns (SingleRedemptionValues memory singleRedemption) {
        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the Trove minus the liquidation reserve
        singleRedemption.CUSDLot = LiquityMath._min(
            _maxCUSDAmount,
            troveManager.getTroveDebt(_borrower).sub(CUSD_GAS_COMPENSATION)
        );

        newColls memory colls;
        uint troveDebt;
        (colls.tokens, colls.amounts, troveDebt) = troveManager.getCurrentTroveState(_borrower);

        uint256 collsLen = colls.tokens.length;
        uint256[] memory finalAmounts = new uint256[](collsLen);


        // redemption addresses are the same as coll addresses for trove
        // Calculation for how much collateral to send of each type. 
        singleRedemption.CollLot.tokens = colls.tokens;
        singleRedemption.CollLot.amounts = new uint256[](collsLen);
        { // limit scope

            uint256 totalCollUSD = _getUSDColls(colls);
            uint256 baseLot = singleRedemption.CUSDLot.mul(DECIMAL_PRECISION);
            for (uint256 i; i < collsLen; ++i) {
                uint tokenAmountToRedeem = baseLot.mul(colls.amounts[i]).div(totalCollUSD).div(1e18);
                finalAmounts[i] = colls.amounts[i].sub(tokenAmountToRedeem);
                singleRedemption.CollLot.amounts[i] = tokenAmountToRedeem;
                // For wrapped assets, update the wrapped token reward to this contract temporarily 
                // to consolidate all trove's rewards. This is transferred all to the redeemer later. 
                if (whitelist.isWrapped(colls.tokens[i])) {
                    IWAsset(colls.tokens[i]).updateReward(_borrower, address(this), tokenAmountToRedeem);
                }
            }
        }

        // Decrease the debt and collateral of the current Trove according to the CUSD lot and corresponding Collateral to send
        uint256 newDebt = troveDebt.sub(singleRedemption.CUSDLot);

        if (newDebt == CUSD_GAS_COMPENSATION) {
            // No debt left in the Trove (except for the liquidation reserve), therefore the trove gets closed
            troveManager.removeStakeTMR(_borrower);
            troveManager.closeTroveRedemption(_borrower);
            _redeemCloseTrove(
                _contractsCache,
                _borrower,
                CUSD_GAS_COMPENSATION,
                colls.tokens,
                finalAmounts
            );

            address[] memory emptyTokens = new address[](0);
            uint256[] memory emptyAmounts = new uint256[](0);

            emit TroveUpdated(
                _borrower,
                0,
                emptyTokens,
                emptyAmounts,
                TroveManagerOperation.redeemCollateral
            );
        } else {
            uint256 newRICR = LiquityMath._computeCR(_getRVC(colls.tokens, finalAmounts), newDebt); 

            /*
             * If the provided hint is too inaccurate of date, we bail since trying to reinsert without a good hint will almost
             * certainly result in running out of gas. Arbitrary measures of this mean newICR must be greater than hint ICR - 2%, 
             * and smaller than hint ICR + 2%.
             *
             * If the resultant net debt of the partial is less than the minimum, net debt we bail.
             */

            if (newRICR >= _partialRedemptionHintRICR.add(2e16) || 
                newRICR <= _partialRedemptionHintRICR.sub(2e16) || 
                _getNetDebt(newDebt) < MIN_NET_DEBT) {
                singleRedemption.cancelledPartial = true;
                return singleRedemption;
            }

            _contractsCache.sortedTroves.reInsert(
                _borrower,
                newRICR, 
                _upperPartialRedemptionHint,
                _lowerPartialRedemptionHint
            );

            troveManager.updateTroveDebt(_borrower, newDebt);
            collsLen = colls.tokens.length;
            for (uint256 i; i < collsLen; ++i) {
                colls.amounts[i] = finalAmounts[i];
            }
            troveManager.updateTroveCollTMR(_borrower, colls.tokens, colls.amounts);
            troveManager.updateStakeAndTotalStakes(_borrower);

            emit TroveUpdated(
                _borrower,
                newDebt,
                colls.tokens,
                finalAmounts,
                TroveManagerOperation.redeemCollateral
            );
        }
    }

    /*
     * Called when a full redemption occurs, and closes the trove.
     * The redeemer swaps (debt - liquidation reserve) CUSD for (debt - liquidation reserve) worth of Collateral, so the CUSD liquidation reserve left corresponds to the remaining debt.
     * In order to close the trove, the CUSD liquidation reserve is burned, and the corresponding debt is removed from the active pool.
     * The debt recorded on the trove's struct is zero'd elswhere, in _closeTrove.
     * Any surplus Collateral left in the trove, is sent to the Coll surplus pool, and can be later claimed by the borrower.
     */
    function _redeemCloseTrove(
        ContractsCache memory _contractsCache,
        address _borrower,
        uint256 _CUSD,
        address[] memory _remainingColls,
        uint256[] memory _remainingCollsAmounts
    ) internal {
        _contractsCache.CUSDToken.burn(gasPoolAddress, _CUSD);
        // Update Active Pool CUSD, and send Collateral to account
        _contractsCache.activePool.decreaseCUSDDebt(_CUSD);

        // send Collaterals from Active Pool to CollSurplus Pool
        _contractsCache.collSurplusPool.accountSurplus(
            _borrower,
            _remainingColls,
            _remainingCollsAmounts
        );
        _contractsCache.activePool.sendCollaterals(
            address(_contractsCache.collSurplusPool),
            _remainingColls,
            _remainingCollsAmounts
        );
    }

    /*
     * This function has two impacts on the baseRate state variable:
     * 1) decays the baseRate based on time passed since last redemption or CUSD borrowing operation.
     * then,
     * 2) increases the baseRate based on the amount redeemed, as a proportion of total supply
     */
    function _updateBaseRateFromRedemption(uint256 _CUSDDrawn, uint256 _totalCUSDSupply)
        internal
        returns (uint256)
    {
        uint256 decayedBaseRate = troveManager.calcDecayedBaseRate();

        /* Convert the drawn Collateral back to CUSD at face value rate (1 CUSD:1 USD), in order to get
         * the fraction of total supply that was redeemed at face value. */
        uint256 redeemedCUSDFraction = _CUSDDrawn.mul(1e18).div(_totalCUSDSupply);

        uint256 newBaseRate = decayedBaseRate.add(redeemedCUSDFraction.div(BETA));
        newBaseRate = LiquityMath._min(newBaseRate, DECIMAL_PRECISION); // cap baseRate at a maximum of 100%

        troveManager.updateBaseRate(newBaseRate);
        return newBaseRate;
    }

    function _isValidFirstRedemptionHint(ISortedTroves _sortedTroves, address _firstRedemptionHint) 
        internal
        view
        returns (bool)
    {
        if (
            _firstRedemptionHint == address(0) ||
            !_sortedTroves.contains(_firstRedemptionHint) || 
            troveManager.getCurrentRICR(_firstRedemptionHint) < MCR
        ) {
            return false;
        }

        address nextTrove = _sortedTroves.getNext(_firstRedemptionHint);
        return nextTrove == address(0) || troveManager.getCurrentICR(nextTrove) < MCR;
    }

    function _requireUserAcceptsFeeRedemption(uint256 _actualFee, uint256 _maxFee) internal pure {
        require(_actualFee <= _maxFee, "TMR:User must accept fee");
    }

    function _requireValidMaxFee(uint256 _CUSDAmount, uint256 _maxCUSDFee) internal pure {
        uint256 _maxFeePercentage = _maxCUSDFee.mul(DECIMAL_PRECISION).div(_CUSDAmount);
        require(_maxFeePercentage >= REDEMPTION_FEE_FLOOR, "TMR:Passed in max fee <0.5%");
        require(_maxFeePercentage <= DECIMAL_PRECISION, "TMR:Passed in max fee >100%");
    }



    function _requireTCRoverMCR() internal view {
        require(_getTCR() >= MCR, "TMR: Cannot redeem when TCR<MCR");
    }

    function _requireAmountGreaterThanZero(uint256 _amount) internal pure {
        require(_amount != 0, "TMR:ReqNonzeroAmount");
    }

    function _requireCUSDBalanceCoversRedemption(
        ICUSDToken _CUSDToken,
        address _redeemer,
        uint256 _amount
    ) internal view {
        require(
            _CUSDToken.balanceOf(_redeemer) >= _amount,
            "TMR:InsufficientCUSDBalance"
        );
    }

    function isNonzero(newColls memory coll) internal pure returns (bool) {
        uint256 collsLen = coll.amounts.length;
        for (uint256 i; i < collsLen; ++i) {
            if (coll.amounts[i] != 0) {
                return true;
            }
        }
        return false;
    }

    function _requireCallerisTroveManager() internal view {
        require(msg.sender == address(troveManager), "TMR:Caller not TM");
    }

    function _getRedemptionFee(uint256 _CUSDRedeemed) internal view returns (uint256) {
        return _calcRedemptionFee(troveManager.getRedemptionRate(), _CUSDRedeemed);
    }

    function _calcRedemptionFee(uint256 _redemptionRate, uint256 _CUSDRedeemed)
        internal
        pure
        returns (uint256)
    {
        uint256 redemptionFee = _redemptionRate.mul(_CUSDRedeemed).div(DECIMAL_PRECISION);
        require(
            redemptionFee < _CUSDRedeemed,
            "TM: Fee > CUSD Redeemed"
        );
        return redemptionFee;
    }

    function _calcRedemptionRate(uint256 _baseRate) internal pure returns (uint256) {
        return
            LiquityMath._min(
                REDEMPTION_FEE_FLOOR.add(_baseRate),
                DECIMAL_PRECISION // cap at a maximum of 100%
            );
    }
}
