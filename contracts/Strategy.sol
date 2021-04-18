// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategyInitializable
} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/Frax/IFXS.sol";
import "../interfaces/Frax/IStakingRewards.sol";
import "../interfaces/Frax/IFrax.sol";
import "../interfaces/Uniswap/IUniswapRouter.sol";
import "../interfaces/Uniswap/IUniswapPair.sol";
import "../interfaces/Uniswap/IUniswapOracle.sol";

contract StrategyFrax is BaseStrategyInitializable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 public constant MAX_GOV_TOKENS_LENGTH = 5;

    uint256 public constant FULL_ALLOC = 100000;

    address public uniswapRouterV2;
    address public uniswapLP;
    address public weth;
    address public stakingContract;
    address public fraxToken;
    address public fxsToken;
    address public usdcToken;

    address public fraxOracle;
    address public fxsOracle;
    uint256 public oraclePeriod;

    bool public checkVirtualPrice;

    bool public checkRedeemedAmount;
    bool public alreadyRedeemed;
    uint256 public redeemThreshold;

    mapping(address => address[]) public paths;

    modifier onlyGovernanceOrManagement() {
        require(
            msg.sender == governance() || msg.sender == vault.management(),
            "!authorized"
        );
        _;
    }

    modifier updatePriceOracles() {
        updateOracles();
        _;
    }

    constructor(
        address _vault,
        address _weth,
        address _stakingContract,
        address _fxsToken,
        address _fraxToken,
        address _usdcToken,
        address _fxsOracle,
        address _fraxOracle,
        address _uniswapLP,
        address _uniswapRouterV2
    ) public BaseStrategyInitializable(_vault) {
        _init(
            _weth,
            _stakingContract,
            _fxsToken,
            _fraxToken,
            _usdcToken,
            _fxsOracle,
            _fraxOracle,
            _uniswapLP,
            _uniswapRouterV2
        );
    }

    function init(
        address _vault,
        address _onBehalfOf,
        address _weth,
        address _stakingContract,
        address _fxsToken,
        address _fraxToken,
        address _usdcToken,
        address _fxsOracle,
        address _fraxOracle,
        address _uniswapLP,
        address _uniswapRouterV2
    ) external {
        super._initialize(_vault, _onBehalfOf, _onBehalfOf, _onBehalfOf);

        _init(
            _weth,
            _stakingContract,
            _fxsToken,
            _fraxToken,
            _usdcToken,
            _fxsOracle,
            _fraxOracle,
            _uniswapLP,
            _uniswapRouterV2
        );
    }

    function _init(
        address _weth,
        address _stakingContract,
        address _fxsToken,
        address _fraxToken,
        address _usdcToken,
        address _fxsOracle,
        address _fraxOracle,
        address _uniswapLP,
        address _uniswapRouterV2
    ) internal {
        require(
            address(want) == _usdcToken,
            "Vault want is different from USDC token underlying"
        );

        weth = _weth;
        stakingContract = _stakingContract;
        fxsToken = _fxsToken;
        fraxToken = _fraxToken;
        usdcToken = _usdcToken;

        fraxOracle = _fraxOracle;
        fxsOracle = _fxsOracle;

        oraclePeriod = IUniswapOracle(_fraxOracle).PERIOD();

        uniswapLP = _uniswapLP;
        uniswapRouterV2 = _uniswapRouterV2;

        alreadyRedeemed = false;
        checkRedeemedAmount = true;
        redeemThreshold = 1;

        want.safeApprove(_stakingContract, type(uint256).max);

        updateOracles();
    }

    function setCheckRedeemedAmount(bool _checkRedeemedAmount)
        external
        onlyGovernanceOrManagement
    {
        checkRedeemedAmount = _checkRedeemedAmount;
    }

    function setRedeemThreshold(uint256 _redeemThreshold)
        external
        onlyGovernanceOrManagement
    {
        redeemThreshold = _redeemThreshold;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return "StrategyFraxFxsUniLP";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return
            want.balanceOf(address(this)).add(wantValueInStaking()).add(
                wantValueInRewards()
            );
    }

    /*
     * Perform any strategy unwinding or other calls necessary to capture the "free return"
     * this strategy has generated since the last time it's core position(s) were adjusted.
     * Examples include unwrapping extra rewards. This call is only used during "normal operation"
     * of a Strategy, and should be optimized to minimize losses as much as possible. This method
     * returns any realized profits and/or realized losses incurred, and should return the total
     * amounts of profits/losses/debt payments (in `want` tokens) for the Vault's accounting
     * (e.g. `want.balanceOf(this) >= _debtPayment + _profit - _loss`).
     *
     * NOTE: `_debtPayment` should be less than or equal to `_debtOutstanding`. It is okay for it
     *       to be less than `_debtOutstanding`, as that should only used as a guide for how much
     *       is left to pay back. Payments should be made to minimize loss from slippage, debt,
     *       withdrawal fees, etc.
     */
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        updatePriceOracles
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // Reset, it could have been set during a withdrawal
        if (alreadyRedeemed) {
            alreadyRedeemed = false;
        }

        // Get debt, currentValue (want+idle), only want
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 currentValue = estimatedTotalAssets();
        uint256 wantBalance = balanceOfWant();

        // Calculate total profit w/o farming
        if (debt < currentValue) {
            _profit = currentValue.sub(debt);
        } else {
            _loss = debt.sub(currentValue);
        }

        // To withdraw = profit from lending + _debtOutstanding
        uint256 toFree = _debtOutstanding.add(_profit);

        // In the case want is not enough exit position by the diferrence
        if (toFree > wantBalance) {
            toFree = toFree.sub(wantBalance);
            uint256 freedAmount = _exitIntoWant(toFree);

            // loss in the case freedAmount is less than what should have be freed
            uint256 withdrawalLoss =
                freedAmount < toFree ? toFree.sub(freedAmount) : 0;

            // profit recalc
            if (withdrawalLoss < _profit) {
                _profit = _profit.sub(withdrawalLoss);
            } else {
                _loss = _loss.add(withdrawalLoss.sub(_profit));
                _profit = 0;
            }
        }

        // If we have fxsTokens, let's convert them!
        // This is done in a separate step since there might have been a migration or an exitPosition
        //
        // Claim only if not done in the previous liquidate step during redeem
        uint256 liquidated = 0;
        if (!alreadyRedeemed) {
            liquidated = _claimAndLiquidateFxs();
        } else {
            alreadyRedeemed = false;
        }

        // Increase profit by liquidated amount
        _profit = _profit.add(liquidated);

        // Recalculate profit
        wantBalance = balanceOfWant();

        if (wantBalance < _profit) {
            _profit = wantBalance;
            _debtPayment = 0;
        } else if (wantBalance < _debtPayment.add(_profit)) {
            _debtPayment = wantBalance.sub(_profit);
        } else {
            _debtPayment = _debtOutstanding;
        }
    }

    /*
     * Perform any adjustments to the core position(s) of this strategy given
     * what change the Vault made in the "investable capital" available to the
     * strategy. Note that all "free capital" in the strategy after the report
     * was made is available for reinvestment. Also note that this number could
     * be 0, and you should handle that scenario accordingly.
     */
    function adjustPosition(uint256 _debtOutstanding)
        internal
        override
        updatePriceOracles
    {
        //emergency exit is dealt with in prepareReturn
        if (emergencyExit) {
            return;
        }

        uint256 balanceOfWant = balanceOfWant();
        if (balanceOfWant > _debtOutstanding) {
            uint256 balanceAvailable = balanceOfWant.sub(_debtOutstanding);
            _swapAndStakeLP(balanceAvailable);
        }
    }

    /*
     * Liquidate as many assets as possible to `want`, irregardless of slippage,
     * up to `_amountNeeded`. Any excess should be re-invested here as well.
     */
    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        updatePriceOracles
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // if current balance can not cover exit position by difference
        if (balanceOfWant() < _amountNeeded) {
            uint256 amountToRedeem = _amountNeeded.sub(balanceOfWant());
            _exitIntoWant(amountToRedeem);
        }

        // returns amount liquidated and loss in case liquidation was samller then needed
        uint256 balanceOfWant = balanceOfWant();

        if (balanceOfWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = balanceOfWant;
            _loss = _amountNeeded.sub(balanceOfWant);
        }
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function harvestTrigger(uint256 callCost)
        public
        view
        override
        returns (bool)
    {
        return super.harvestTrigger(ethToUsdc(callCost));
    }

    function prepareMigration(address _newStrategy)
        internal
        override
        updatePriceOracles
    {
        // this automatically claims the fxs rewards and liquidates them into want
        _claimAndLiquidateFxs();

        //unstakes LP and liquidate everything for want
        uint256 lpStaked =
            IStakingRewards(stakingContract).balanceOf(address(this));
        _unstakeAndLiquidateLP(lpStaked);

        //NOTE: transfer of want to new strategy happens automatically
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](3);
        protected[0] = fxsToken;
        protected[1] = fraxToken;
        protected[2] = uniswapLP;
        return protected;

        return protected;
    }

    // ******** CUSTOM FUNCTIONS AND HELPERS ************

    function updateOracles() public {
        uint256 timestampNow = block.timestamp;
        uint256 lastUpdate = IUniswapOracle(fraxOracle).blockTimestampLast();
        if (timestampNow - lastUpdate >= oraclePeriod) {
            IUniswapOracle(fraxOracle).update();
        }

        lastUpdate = IUniswapOracle(fxsOracle).blockTimestampLast();
        if (timestampNow - lastUpdate >= oraclePeriod) {
            IUniswapOracle(fxsOracle).update();
        }
    }

    // Free an amount of want(USDC) from FRAX Uniswap LP Staking
    function _exitIntoWant(uint256 _amount) internal returns (uint256) {
        uint256 preBalanceOfWant = balanceOfWant();

        uint256 valueInStaking = wantValueInStaking();
        uint256 lpInStaking =
            IStakingRewards(stakingContract).balanceOf(address(this));
        uint256 lpToRedeem = _amount.mul(lpInStaking).div(valueInStaking);

        _unstakeAndLiquidateLP(lpToRedeem);

        uint256 freedAmount = balanceOfWant().sub(preBalanceOfWant);
        if (checkRedeemedAmount) {
            require(
                freedAmount.add(redeemThreshold) >= _amount,
                "Redeemed amount must be >= amountToRedeem"
            );
        }

        return freedAmount;
    }

    // Withdraws from Staking and removes liquidity from Uniswap Pool, then liquidates it into want
    function _unstakeAndLiquidateLP(uint256 _amountLP)
        internal
        returns (uint256 amount)
    {
        //unstake LP
        IStakingRewards(stakingContract).withdraw(_amountLP);

        //remove liquidity from uniswap
        uint256 lpBalance = IUniswapPair(uniswapLP).balanceOf(address(this));
        IUniswapPair(uniswapLP).approve(uniswapLP, lpBalance);
        IUniswapRouter(uniswapRouterV2).removeLiquidity(
            fraxToken,
            address(want),
            lpBalance,
            1,
            1,
            address(this),
            now.add(1800)
        );

        //swap frax for usdc
        uint256 balance = IERC20(fraxToken).balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = address(fraxToken);
        path[1] = address(want);

        uint256[] memory amounts =
            IUniswapRouter(uniswapRouterV2).swapExactTokensForTokens(
                balance,
                1,
                path,
                address(this),
                now.add(1800)
            );

        return amounts[amounts.length - 1];
    }

    // Liquidates entire FXS balance held
    function _claimAndLiquidateFxs() internal returns (uint256 liquidated) {
        IStakingRewards(stakingContract).withdraw(
            IStakingRewards(stakingContract).earned(address(this))
        );

        uint256 balance = IERC20(fxsToken).balanceOf(address(this));

        address[] memory path = new address[](3);
        path[0] = address(fxsToken);
        path[1] = address(weth);
        path[2] = address(want);

        uint256[] memory amounts =
            IUniswapRouter(uniswapRouterV2).swapExactTokensForTokens(
                balance,
                1,
                path,
                address(this),
                now.add(1800)
            );

        return amounts[amounts.length - 1];
    }

    function _swapAndStakeLP(uint256 balanceAvailable)
        internal
        returns (uint256 amount)
    {
        uint256 amountToSwap = balanceAvailable.div(2);

        //swap usdc for frax
        address[] memory path = new address[](2);
        path[0] = address(want);
        path[1] = address(fraxToken);

        IUniswapRouter(uniswapRouterV2).swapExactTokensForTokens(
            amountToSwap,
            1,
            path,
            address(this),
            now.add(1800)
        );

        //deposit both into LP
        IUniswapRouter(uniswapRouterV2).addLiquidity(
            fraxToken,
            address(want),
            IERC20(fraxToken).balanceOf(address(this)),
            want.balanceOf(address(this)),
            1,
            1,
            address(this),
            now.add(1800)
        );

        //stake lp tokens
        amount = IUniswapPair(uniswapLP).balanceOf(address(this));
        IStakingRewards(stakingContract).stake(amount);
    }

    // ******** CUSTOM VIEWS AND HELPERS ************

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function wantValueInStaking() public view returns (uint256 totalValueUsdc) {
        uint256 stakedLP =
            IStakingRewards(stakingContract).balanceOf(address(this));
        uint256 supplyLP = IUniswapPair(uniswapLP).totalSupply();

        (uint112 reservesFrax, uint112 reservesUsdc, uint32 _) =
            IUniswapPair(uniswapLP).getReserves();

        uint256 fraxBalance =
            (uint256(reservesFrax).mul(stakedLP)).div(supplyLP);
        uint256 usdcBalance =
            (uint256(reservesUsdc).mul(stakedLP)).div(supplyLP);

        uint256 fraxToUsdc =
            fraxBalance.mul(10**6).div(IFrax(fraxToken).frax_price()).add(1); // Frax price has 6 decimals

        totalValueUsdc = usdcBalance.add(fraxToUsdc);
    }

    function wantValueInRewards() public view returns (uint256 fxsValue) {
        uint256 fxsEarned =
            IStakingRewards(stakingContract).earned(address(this));
        fxsValue = fxsEarned.mul(IFrax(fraxToken).fxs_price()).div(10**6).add(
            1
        ); // Fxs price has 6 decimals
    }

    function ethToUsdc(uint256 _amount) public view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(want);
        uint256[] memory amounts =
            IUniswapRouter(uniswapRouterV2).getAmountsOut(_amount, path);

        return amounts[amounts.length - 1];
    }
}
