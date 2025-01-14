// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ERC20.sol";
import "./Export.sol";
import "./CounterstakeLibrary.sol";

contract ExportAssistant is ERC20, ReentrancyGuard, CounterstakeReceiver 
{

	address public bridgeAddress;
	address public tokenAddress;
	address public managerAddress;

	uint16 public management_fee10000;
	uint16 public success_fee10000;

	uint8 public exponent;
	
	uint public ts;
	int public profit;
	uint public mf;
	uint public balance_in_work;

	mapping(uint => uint) public balances_in_work;

	Governance public governance;


	event NewClaimFor(uint claim_num, address for_address, string txid, uint32 txts, uint amount, int reward, uint stake);
	event AssistantChallenge(uint claim_num, CounterstakeLibrary.Side outcome, uint stake);
    event NewManager(address previousManager, address newManager);


	modifier onlyETH(){
		require(tokenAddress == address(0), "ETH only");
		_;
	}

/*	modifier onlyERC20(){
		require(tokenAddress != address(0), "ERC20 only");
		_;
	}*/

	modifier onlyBridge(){
		require(msg.sender == bridgeAddress, "not from bridge");
		_;
	}

    modifier onlyManager() {
        require(msg.sender == managerAddress, "caller is not the manager");
        _;
    }


	constructor(address bridgeAddr, address managerAddr, uint16 _management_fee10000, uint16 _success_fee10000, uint8 _exponent, string memory name, string memory symbol) ERC20(name, symbol) {
		initExportAssistant(bridgeAddr, managerAddr, _management_fee10000, _success_fee10000, _exponent, name, symbol);
	}

	function initExportAssistant(address bridgeAddr, address managerAddr, uint16 _management_fee10000, uint16 _success_fee10000, uint8 _exponent, string memory _name, string memory _symbol) public {
		require(address(governance) == address(0), "already initialized");
		name = _name;
		symbol = _symbol;
		bridgeAddress = bridgeAddr;
		management_fee10000 = _management_fee10000;
		success_fee10000 = _success_fee10000;
		require(_exponent == 1 || _exponent == 2 || _exponent == 4, "only exponents 1, 2 and 4 are supported");
		exponent = _exponent;
		ts = block.timestamp;
		(address tokenAddr, , , , , ) = Export(bridgeAddr).settings();
		tokenAddress = tokenAddr;
		if (tokenAddr != address(0))
			IERC20(tokenAddr).approve(bridgeAddr, type(uint).max);
		managerAddress = (managerAddr != address(0)) ? managerAddr : msg.sender;
	}


	function getGrossBalance() internal view returns (uint) {
		uint bal = (tokenAddress == address(0)) ? address(this).balance : IERC20(tokenAddress).balanceOf(address(this));
		return bal + balance_in_work;
	}

	function updateMFAndGetBalances(uint just_received_amount, bool update) internal returns (uint gross_balance, int net_balance) {
		gross_balance = getGrossBalance() - just_received_amount;
		uint new_mf = mf + gross_balance * management_fee10000 * (block.timestamp - ts)/(360*24*3600)/1e4;
		net_balance = int(gross_balance) - int(new_mf) - max(profit * int16(success_fee10000)/1e4, 0);
		// to save gas, we don't update mf when the balance doesn't change
		if (update) {
			mf = new_mf;
			ts = block.timestamp;
		}
	}


	// reentrancy is probably not a risk unless a malicious token makes a reentrant call from its balanceOf, so nonReentrant can be removed to save 10K gas
	function claim(string memory txid, uint32 txts, uint amount, int reward, string memory sender_address, address payable recipient_address, string memory data) onlyManager nonReentrant external {
		require(reward >= 0, "negative reward");
		uint claim_num = Export(bridgeAddress).last_claim_num() + 1;
		uint required_stake = Export(bridgeAddress).getRequiredStake(amount);
		uint paid_amount = amount - uint(reward);
		uint total = required_stake + paid_amount;
		{ // stack too deep
			(, int net_balance) = updateMFAndGetBalances(0, false);
			require(total < uint(type(int).max), "total too large");
			require(net_balance > 0, "no net balance");
			require(total <= uint(net_balance), "not enough balance");
			balances_in_work[claim_num] = total;
			balance_in_work += total;
		}

		emit NewClaimFor(claim_num, recipient_address, txid, txts, amount, reward, required_stake);

		Export(bridgeAddress).claim{value: tokenAddress == address(0) ? total : 0}(txid, txts, amount, reward, required_stake, sender_address, recipient_address, data);
	}

	// like in claim() above, nonReentrant is probably unnecessary
	function challenge(uint claim_num, CounterstakeLibrary.Side stake_on, uint stake) onlyManager nonReentrant external {
		(, int net_balance) = updateMFAndGetBalances(0, false);
		require(net_balance > 0, "no net balance");

		uint missing_stake = Export(bridgeAddress).getMissingStake(claim_num, stake_on);
		if (stake == 0 || stake > missing_stake) // send the stake without excess as we can't account for it
			stake = missing_stake;

		require(stake <= uint(net_balance), "not enough balance");
		Export(bridgeAddress).challenge{value: tokenAddress == address(0) ? stake : 0}(claim_num, stake_on, stake);
		balances_in_work[claim_num] += stake;
		balance_in_work += stake;
		emit AssistantChallenge(claim_num, stake_on, stake);
	}

	receive() external payable onlyETH {
		// silently receive Ether from claims
	}

	function onReceivedFromClaim(uint claim_num, uint claimed_amount, uint won_stake, string memory, address, string memory) onlyBridge override external {
		uint total = claimed_amount + won_stake;
		updateMFAndGetBalances(total, true); // total is already added to our balance

		uint invested = balances_in_work[claim_num];
		require(invested > 0, "BUG: I didn't stake in this claim?");

		if (total >= invested){
			uint this_profit = total - invested;
			require(this_profit < uint(type(int).max), "this_profit too large");
			profit += int(this_profit);
		}
		else { // avoid negative values
			uint loss = invested - total;
			require(loss < uint(type(int).max), "loss too large");
			profit -= int(loss);
		}

		balance_in_work -= invested;
		delete balances_in_work[claim_num];
	}

	// Record a loss, called by anybody.
	// Should be called only if I staked on the losing side only.
	// If I staked on the winning side too, the above function should be called.
	function recordLoss(uint claim_num) nonReentrant external {
		updateMFAndGetBalances(0, true);

		uint invested = balances_in_work[claim_num];
		require(invested > 0, "this claim is already accounted for");
		
		CounterstakeLibrary.Claim memory c = Export(bridgeAddress).getClaim(claim_num);
		require(c.amount > 0, "no such claim");
		require(block.timestamp > c.expiry_ts, "not expired yet");
		CounterstakeLibrary.Side opposite_outcome = c.current_outcome == CounterstakeLibrary.Side.yes ? CounterstakeLibrary.Side.no : CounterstakeLibrary.Side.yes;
		
		uint my_winning_stake = Export(bridgeAddress).stakes(claim_num, c.current_outcome, address(this));
		require(my_winning_stake == 0, "have a winning stake in this claim");
		
		uint my_losing_stake = Export(bridgeAddress).stakes(claim_num, opposite_outcome, address(this));
		require(my_losing_stake > 0, "no losing stake in this claim");
		require(invested >= my_losing_stake, "lost more than invested?");

		require(invested < uint(type(int).max), "loss too large");
		profit -= int(invested);

		balance_in_work -= invested;
		delete balances_in_work[claim_num];
	}


	// share issue/redeem functions

	function buyShares(uint stake_asset_amount) payable nonReentrant external {
		if (tokenAddress == address(0))
			require(msg.value == stake_asset_amount, "wrong amount received");
		else {
			require(msg.value == 0, "don't send ETH");
			require(IERC20(tokenAddress).transferFrom(msg.sender, address(this), stake_asset_amount), "failed to pull to buy shares");
		}
		(uint gross_balance, int net_balance) = updateMFAndGetBalances(stake_asset_amount, true);
		require((gross_balance == 0) == (totalSupply() == 0), "bad init state");
		uint shares_amount;
		if (totalSupply() == 0)
			shares_amount = stake_asset_amount / 10**(18 - decimals());
		else {
			require(net_balance > 0, "no net balance");
			uint new_shares_supply = totalSupply() * getShares(uint(net_balance) + stake_asset_amount) / getShares(uint(net_balance));
			shares_amount = new_shares_supply - totalSupply();
		}
		_mint(msg.sender, shares_amount);

		// this should overflow now, not when we try to redeem. We won't see the error message, will revert while trying to evaluate the expression
		require((gross_balance + stake_asset_amount) * totalSupply()**exponent > 0, "too many shares, would overflow");
	}

	function redeemShares(uint shares_amount) nonReentrant external {
		uint old_shares_supply = totalSupply();

		_burn(msg.sender, shares_amount);
		(, int net_balance) = updateMFAndGetBalances(0, true);
		require(net_balance > 0, "negative net balance");
		require(uint(net_balance) > balance_in_work, "negative risk-free net balance");

		uint stake_asset_amount = (uint(net_balance) - balance_in_work) * (old_shares_supply**exponent - (old_shares_supply - shares_amount)**exponent) / old_shares_supply**exponent;
		payStakeTokens(msg.sender, stake_asset_amount);
	}


	// manager functions

	function withdrawManagementFee() onlyManager nonReentrant external {
		updateMFAndGetBalances(0, true);
		payStakeTokens(msg.sender, mf);
		mf = 0;
	}

	function withdrawSuccessFee() onlyManager nonReentrant external {
		updateMFAndGetBalances(0, true);
		require(profit > 0, "no profit yet");
		uint sf = uint(profit) * success_fee10000/1e4;
		payStakeTokens(msg.sender, sf);
		profit = 0;
	}

	// zero address is allowed
    function assignNewManager(address newManager) onlyManager external {
		emit NewManager(managerAddress, newManager);
        managerAddress = newManager;
    }


	// governance functions

	modifier onlyVotedValueContract(){
		require(governance.addressBelongsToGovernance(msg.sender), "not from voted value contract");
		_;
	}

	// would be happy to call this from the constructor but unfortunately `this` is not set at that time yet
	function setupGovernance(GovernanceFactory governanceFactory, VotedValueFactory ) external {
		require(address(governance) == address(0), "already initialized");
		governance = governanceFactory.createGovernance(address(this), address(this));

	}



	// helper functions

	function payStakeTokens(address to, uint amount) internal {
		if (tokenAddress == address(0))
			payable(to).transfer(amount);
		else
			require(IERC20(tokenAddress).transfer(to, amount), "failed to transfer");
	}

	function getShares(uint balance) view internal returns (uint) {
		if (exponent == 1)
			return balance;
		if (exponent == 2)
			return sqrt(balance);
		if (exponent == 4)
			return sqrt(sqrt(balance));
		revert("bad exponent");
	}

	// for large exponents, we need more room to **exponent without overflow
	function decimals() public view override returns (uint8) {
		return exponent > 2 ? 9 : 18;
	}

	function max(int a, int b) internal pure returns (int) {
		return a > b ? a : b;
	}

	// babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
	function sqrt(uint y) internal pure returns (uint z) {
		if (y > 3) {
			z = y;
			uint x = y / 2 + 1;
			while (x < z) {
				z = x;
				x = (y / x + x) / 2;
			}
		} else if (y != 0) {
			z = 1;
		}
	}

}

