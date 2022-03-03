// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

import "./Auth.sol";
import "./IBEP20.sol";
import "./IDexRouter.sol";
import "./IDexFactory.sol";

contract Watchdog is IBEP20, Auth {

	address DEAD = 0x000000000000000000000000000000000000dEaD;
    address ZERO = 0x0000000000000000000000000000000000000000;

	string constant _name = "Watchdog";
    string constant _symbol = "WDP";
    uint8 constant _decimals = 18;

    uint256 _totalSupply = 200_000_000 * (10 ** _decimals);
    uint256 public _maxTxAmount = _totalSupply / 1;
	uint256 public _maxWalletAmount = _totalSupply / 1;

	mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;
    mapping (address => bool) isFeeExempt;
    mapping (address => bool) isTxLimitExempt;

	// Fees.
	uint256 public liquidityFee = 20;
    uint256 public ecosystemFee = 10;
	uint256 public marketingFee = 10;
	uint256 public liquidityFeeSell = 40;
    uint256 public ecosystemFeeSell = 20;
	uint256 public marketingFeeSell = 20;
    uint256 public feeDenominator = 1000;
	bool public feeOnNonTrade = false;
	bool public disableLiqFeeOverLiquid = true;

	// Get BUSD as fee.
	address BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
	bool getBusdDev = true;

	address public autoLiquidityReceiver;
	address public ecosystemReceiver;
	address public marketingReceiver;
	uint256 sendBnbGas = 34000;

	IDexRouter public router;
    address bnbPair;
	mapping(address => bool) public pairs;

	uint256 targetLiquidity = 25;
    uint256 targetLiquidityDenominator = 100;

	bool public swapEnabled = true;
    uint256 public swapThreshold = _totalSupply / 2000;
	bool public swapAllTokens = true;
    bool inSwap;
    modifier swapping() {
		inSwap = true;
		_;
		inSwap = false;
	}

	uint256 public launchedAt = 0;
	uint256 private antiSniperBlocks = 2;
	mapping (address => bool) sniper;

	event AutoLiquifyEnabled(bool enabledOrNot);
	event AutoLiquify(uint256 amountBNB, uint256 autoBuybackAmount);

	constructor(address rout) Auth(msg.sender) {
		router = IDexRouter(rout);
        bnbPair = IDexFactory(router.factory()).createPair(router.WETH(), address(this));
        _allowances[address(this)][address(router)] = type(uint256).max;

		isFeeExempt[msg.sender] = true;
        isFeeExempt[address(this)] = true;
		isTxLimitExempt[msg.sender] = true;
		isTxLimitExempt[address(this)] = true;
        isTxLimitExempt[DEAD] = true;
        isTxLimitExempt[ZERO] = true;

		autoLiquidityReceiver = msg.sender;
		pairs[bnbPair] = true;
		_balances[msg.sender] = _totalSupply;

		emit Transfer(address(0), msg.sender, _totalSupply);
	}

	receive() external payable {}
    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function decimals() external pure override returns (uint8) { return _decimals; }
    function symbol() external pure override returns (string memory) { return _symbol; }
    function name() external pure override returns (string memory) { return _name; }
    function getOwner() external view override returns (address) { return owner; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function approveMax(address spender) external returns (bool) {
        return approve(spender, type(uint256).max);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

	function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        if (_allowances[sender][msg.sender] != type(uint256).max) {
			require(_allowances[sender][msg.sender] >= amount, "Insufficient Allowance");
            _allowances[sender][msg.sender] -= amount;
        }

        return _transferFrom(sender, recipient, amount);
    }

	function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
		require(amount > 0, "Standard does not allow for 0 token transfers.");
        if (inSwap) {
            return _basicTransfer(sender, recipient, amount);
        }

        checkTxLimit(sender, recipient, amount);

        if (shouldSwapBack()) {
            liquify();
        }

		if (sniper[sender] || sniper[recipient]) {
			revert("Sniper blocked.");
		}

		require(amount <= _balances[sender], "Insufficient Balance");
        _balances[sender] -= amount;

        uint256 amountReceived = shouldTakeFee(sender, recipient) ? takeFee(sender, recipient, amount, pairs[recipient]) : amount;
        _balances[recipient] += amountReceived;

        emit Transfer(sender, recipient, amountReceived);
        return true;
    }

	function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
		require(amount <= _balances[sender], "Insufficient Balance");
        _balances[sender] -= amount;
        _balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }

	function checkTxLimit(address sender, address recipient, uint256 amount) internal view {
        require(amount <= _maxTxAmount || isTxLimitExempt[sender] || isTxLimitExempt[recipient] && sender == bnbPair, "TX Limit Exceeded");
		// Max wallet check.
		if (sender != owner
            && recipient != owner
            && !isTxLimitExempt[recipient]
            && recipient != ZERO 
            && recipient != DEAD 
            && recipient != bnbPair 
            && recipient != address(this)
        ) {
            uint256 newBalance = balanceOf(recipient) + amount;
            require(newBalance <= _maxWalletAmount, "Exceeds max wallet.");
        }
    }

	// Decides whether this trade should take a fee.
	// Trades with pairs are always taxed, unless sender or receiver is exempted.
	// Non trades, like wallet to wallet, are configured, untaxed by default.
	function shouldTakeFee(address sender, address recipient) internal view returns (bool) {
        if (isFeeExempt[sender] || isFeeExempt[recipient] || !launched()) {
			return false;
		}

		if (pairs[sender] == true || pairs[recipient] == true) {
			return true;
		}

        return feeOnNonTrade;
    }

	function setAntisniperBlocks(uint256 blocks) external authorized {
		antiSniperBlocks = blocks;
	}

	function takeFee(address sender, address recipient, uint256 amount, bool isSale) internal returns (uint256) {
		if (!launched()) {
			return amount;
		}
		uint256 liqFeePercentage = isSale ? liquidityFeeSell : liquidityFee;
		uint256 devFeePercentage = isSale ? marketingFeeSell : marketingFee;
		uint256 ecoFeePercentage = isSale ? ecosystemFeeSell : ecosystemFee;
		uint256 liqFee = 0;
		uint256 ecoFee = 0;
		uint256 devFee = 0;

		// Anti snipe liquidity fee.
		if (block.number - launchedAt <= antiSniperBlocks && msg.sender != owner) {
			liqFee = amount * feeDenominator - 1 / feeDenominator;
            _balances[address(this)] += liqFee;
			amount -= liqFee;
			if (pairs[sender]) {
				sniper[recipient] = true;
			}
			emit Transfer(sender, address(this), liqFee);
        } else {
			// If there is a liquidity tax active for autoliq, the contract keeps it.
			// If dev fee is active, it is also stored on contract.
			// Swap event takes care of the proper share.
			if (liqFeePercentage > 0 || devFeePercentage > 0) {
				// Only take liquidity fee if it's either not over liquified or disable fee on over liquidity is off.
				if (!disableLiqFeeOverLiquid || !isOverLiquified(targetLiquidity, targetLiquidityDenominator)) {
					liqFee = amount * liqFeePercentage / feeDenominator;
				}
				devFee = amount * devFeePercentage / feeDenominator;
				_balances[address(this)] += liqFee + devFee;
				emit Transfer(sender, address(this), liqFee + devFee);
			}
			// If ecosystem fee is active, it is given to predetermined address.
			if (ecoFeePercentage > 0) {
				ecoFee = amount * ecoFeePercentage / feeDenominator;
				_balances[ecosystemReceiver] += ecoFee;
				emit Transfer(sender, ecosystemReceiver, ecoFee);
			}
		}

        return amount - liqFee - ecoFee - devFee;
    }

	function setEcosystemAddress(address addy) external authorized {
		ecosystemReceiver = addy;
		isFeeExempt[addy] = true;
		isTxLimitExempt[addy] = true;
	}

    function shouldSwapBack() internal view returns (bool) {
        return launched()
			&& msg.sender != bnbPair
            && !inSwap
            && swapEnabled
            && _balances[address(this)] >= swapThreshold;
    }

	function setSwapEnabled(bool set) external authorized {
		swapEnabled = set;
		emit AutoLiquifyEnabled(set);
	}

	function setSwapTreshold(uint256 treshold, bool swapAll) external authorized {
		swapThreshold = treshold;
		swapAllTokens = swapAll;
	}

	function liquify() internal swapping {
		// Make sure Router is always allowed to move these quantities to manage fees.
		if (_allowances[address(this)][address(router)] != type(uint256).max) {
            _allowances[address(this)][address(router)] = type(uint256).max;
        }

		// Swap entirety of tokens when above treshold or just treshold?
		uint256 tokensToSwap = swapAllTokens ? _balances[address(this)] : swapThreshold;
		uint256 toMarketing;

		// Only add liquidity if necessary.
		if (!disableLiqFeeOverLiquid || !isOverLiquified(targetLiquidity, targetLiquidityDenominator)) {
			// Amount for liquidity is the part of the liquidity tax over the total tax that gives the contract tokens.
			uint256 totalTax = liquidityFeeSell + marketingFeeSell;
			uint256 toLiquify = ((tokensToSwap * liquidityFeeSell) / totalTax) / 2;

			// Sell the tokens to get back the BNB.
			sellTokens(tokensToSwap - toLiquify);

			uint256 liquidityBalance = (address(this).balance * toLiquify) / tokensToSwap;
			toMarketing = address(this).balance - liquidityBalance;

			// Add the LP.
			router.addLiquidityETH{value: liquidityBalance}(
				address(this),
				toLiquify,
				0,
				0,
				autoLiquidityReceiver,
				block.timestamp
			);
			emit AutoLiquify(liquidityBalance, toLiquify);
		} else {
			sellTokens(tokensToSwap);
			toMarketing = address(this).balance;
		}

		// Swap the BNB for marketing for BUSD and send it to marketing receiver directly.
		if (getBusdDev) {
			buyBUSD(toMarketing, marketingReceiver);
		} else {
			(bool sent, bytes memory data) = marketingReceiver.call{value: toMarketing, gas: sendBnbGas}("");
		}
    }

	function sellTokens(uint256 amount) internal {
		address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp
        );
	}

	function buyBUSD(uint256 amount, address receiver) internal {
		address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(BUSD);
		router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0,
            path,
            receiver,
            block.timestamp
        );
	}

	function launched() internal view returns (bool) {
        return launchedAt != 0;
    }

	function setLaunched() external authorized {
		require(!launched());
		launch();
	}

    function launch() internal {
        launchedAt = block.number;
    }

	function setTxLimit(uint256 amount) external authorized {
        require(amount >= _totalSupply / 1000);
        _maxTxAmount = amount;
    }

	function setMaxWallet(uint256 amount) external authorized {
		require(amount >= _totalSupply / 1000);
		_maxWalletAmount = amount;
	}

    function setIsFeeExempt(address holder, bool exempt) external authorized {
        isFeeExempt[holder] = exempt;
    }

    function setIsTxLimitExempt(address holder, bool exempt) external authorized {
        isTxLimitExempt[holder] = exempt;
    }

    function setFees(uint256 _liquidityFee, uint256 _ecoFee, uint256 _devFee, uint256 _feeDenominator) external authorized {
        liquidityFee = _liquidityFee;
        ecosystemFee = _ecoFee;
		marketingFee = _devFee;
        feeDenominator = _feeDenominator;
		uint256 totalFee = _liquidityFee + _ecoFee + _devFee ;
        require(totalFee < feeDenominator / 3, "Maximum allowed taxation on this contract is 33%.");
    }

	function setSaleFees(uint256 _liquidityFee, uint256 _ecoFee, uint256 _devFee, uint256 _feeDenominator) external authorized {
        liquidityFeeSell = _liquidityFee;
        ecosystemFeeSell = _ecoFee;
		marketingFeeSell = _devFee;
        feeDenominator = _feeDenominator;
		uint256 totalFee = _liquidityFee + _ecoFee + _devFee ;
        require(totalFee < feeDenominator / 3, "Maximum allowed taxation on this contract is 33%.");
    }

    function setLiquidityReceiver(address _autoLiquidityReceiver) external authorized {
        autoLiquidityReceiver = _autoLiquidityReceiver;
    }

	function setMarketingReceiver(address _receiver) external authorized {
        marketingReceiver = _receiver;
    }

	function getCirculatingSupply() public view returns (uint256) {
        return _totalSupply - balanceOf(DEAD) - balanceOf(ZERO);
    }

	// Recover any BNB sent to the contract by mistake.
	function rescue() external {
        payable(owner).transfer(address(this).balance);
    }

	function setIsPair(address pair, bool isit) external authorized {
        pairs[pair] = isit;
    }

	function setRouter(address r) external authorized {
		router = IDexRouter(r);
        bnbPair = IDexFactory(router.factory()).createPair(router.WETH(), address(this));
        _allowances[address(this)][address(router)] = type(uint256).max;
	}

	function setSniper(address snipy) external authorized {
		require(block.number < launchedAt + 3000, "Launch has passed.");
		sniper[snipy] = true;
	}

	function removeSniper(address snipy) external authorized {
		sniper[snipy] = false;
	}

	function setSendGas(uint256 gas) external authorized {
		sendBnbGas = gas;
	}

	function setBusdSettings(address busd, bool enabled) external authorized {
		BUSD = busd;
		getBusdDev = enabled;
	}

	function setTargetLiquidity(uint256 _target, uint256 _denominator, bool _disable) external onlyOwner {
        targetLiquidity = _target;
        targetLiquidityDenominator = _denominator;
		disableLiqFeeOverLiquid = _disable;
    }

	function isOverLiquified(uint256 target, uint256 accuracy) public view returns (bool) {
        return getLiquidityBacking(accuracy) > target;
    }

	function getLiquidityBacking(uint256 accuracy) public view returns (uint256) {
        return accuracy * balanceOf(bnbPair) / getCirculatingSupply();
    }
}
