pragma solidity ^0.4.21;

import "./usingOraclize.sol";
import "./EOSBetBankroll.sol";
import "./SafeMath.sol";

contract EOSBetDice is usingOraclize, EOSBetGameInterface {

	using SafeMath for *;

	// events
	event BuyRolls(bytes32 indexed oraclizeQueryId);
	event LedgerProofFailed(bytes32 indexed oraclizeQueryId);
	event Refund(bytes32 indexed oraclizeQueryId, uint256 amount);
	event DiceSmallBet(uint16 actualRolls, uint256 data1, uint256 data2, uint256 data3, uint256 data4);
	event DiceLargeBet(bytes32 indexed oraclizeQueryId, uint16 actualRolls, uint256 data1, uint256 data2, uint256 data3, uint256 data4);

	// game data structure
	struct DiceGameData {
		address player;
		bool paidOut;
		uint256 start;
		uint256 etherReceived;
		uint256 betPerRoll;
		uint16 rolls;
		uint8 rollUnder;
	}

	mapping (bytes32 => DiceGameData) public diceData;

	// ether in this contract can be in one of two locations:
	uint256 public LIABILITIES;
	uint256 public DEVELOPERSFUND;

	// counters for frontend statistics
	uint256 public AMOUNTWAGERED;
	uint256 public GAMESPLAYED;
	
	// togglable values
	uint256 public ORACLIZEQUERYMAXTIME;
	uint256 public MINBET_perROLL;
	uint256 public MINBET_perTX;
	uint256 public ORACLIZEGASPRICE;
	uint256 public INITIALGASFORORACLIZE;
	uint8 public HOUSEEDGE_inTHOUSANDTHPERCENTS; // 1 thousanthpercent == 1/1000, 
	uint8 public MAXWIN_inTHOUSANDTHPERCENTS; // determines the maximum win a user may receive.

	// togglable functionality of contract
	bool public GAMEPAUSED;
	bool public REFUNDSACTIVE;

	// owner of contract
	address public OWNER;

	// bankroller address
	address public BANKROLLER;

	// constructor
	function EOSBetDice() public {
		// ledger proof is ALWAYS verified on-chain
		oraclize_setProof(proofType_Ledger);

		// gas prices for oraclize call back, can be changed
		oraclize_setCustomGasPrice(8000000000);
		ORACLIZEGASPRICE = 8000000000;
		INITIALGASFORORACLIZE = 300000;

		AMOUNTWAGERED = 0;
		GAMESPLAYED = 0;

		GAMEPAUSED = false;
		REFUNDSACTIVE = true;

		ORACLIZEQUERYMAXTIME = 6 hours;
		MINBET_perROLL = 20 finney;
		MINBET_perTX = 100 finney;
		HOUSEEDGE_inTHOUSANDTHPERCENTS = 5; // 5/1000 == 0.5% house edge
		MAXWIN_inTHOUSANDTHPERCENTS = 20; // 20/1000 == 2.0% of bankroll can be won in a single bet, will be lowered once there is more investors
		OWNER = msg.sender;
	}

	////////////////////////////////////
	// INTERFACE CONTACT FUNCTIONS
	////////////////////////////////////

	function payDevelopersFund(address developer) public {
		require(msg.sender == BANKROLLER);

		uint256 devFund = DEVELOPERSFUND;

		DEVELOPERSFUND = 0;

		developer.transfer(devFund);
	}

	// just a function to receive eth, only allow the bankroll to use this
	function receivePaymentForOraclize() payable public {
		require(msg.sender == BANKROLLER);
	}

	////////////////////////////////////
	// VIEW FUNCTIONS
	////////////////////////////////////

	function getMaxWin() public view returns(uint256){
		return (SafeMath.mul(EOSBetBankrollInterface(BANKROLLER).getBankroll(), MAXWIN_inTHOUSANDTHPERCENTS) / 1000);
	}

	////////////////////////////////////
	// OWNER ONLY FUNCTIONS
	////////////////////////////////////

	// WARNING!!!!! Can only set this function once!
	function setBankrollerContractOnce(address bankrollAddress) public {
		// require that BANKROLLER address == 0 (address not set yet), and coming from owner.
		require(msg.sender == OWNER && BANKROLLER == address(0));

		// check here to make sure that the bankroll contract is legitimate
		// just make sure that calling the bankroll contract getBankroll() returns non-zero

		require(EOSBetBankrollInterface(bankrollAddress).getBankroll() != 0);

		BANKROLLER = bankrollAddress;
	}

	function transferOwnership(address newOwner) public {
		require(msg.sender == OWNER);

		OWNER = newOwner;
	}

	function setOraclizeQueryMaxTime(uint256 newTime) public {
		require(msg.sender == OWNER);

		ORACLIZEQUERYMAXTIME = newTime;
	}

	// store the gas price as a storage variable for easy reference,
	// and then change the gas price using the proper oraclize function
	function setOraclizeQueryGasPrice(uint256 gasPrice) public {
		require(msg.sender == OWNER);

		ORACLIZEGASPRICE = gasPrice;
		oraclize_setCustomGasPrice(gasPrice);
	}

	// should be ~175,000 to save eth
	function setInitialGasForOraclize(uint256 gasAmt) public {
		require(msg.sender == OWNER);

		INITIALGASFORORACLIZE = gasAmt;
	}

	function setGamePaused(bool paused) public {
		require(msg.sender == OWNER);

		GAMEPAUSED = paused;
	}

	function setRefundsActive(bool active) public {
		require(msg.sender == OWNER);

		REFUNDSACTIVE = active;
	}

	function setHouseEdge(uint8 houseEdgeInThousandthPercents) public {
		// house edge cannot be set > 5%, can be set to zero for promotions
		require(msg.sender == OWNER && houseEdgeInThousandthPercents <= 50);

		HOUSEEDGE_inTHOUSANDTHPERCENTS = houseEdgeInThousandthPercents;
	}

	function setMinBetPerRoll(uint256 minBet) public {
		require(msg.sender == OWNER && minBet > 1000);

		MINBET_perROLL = minBet;
	}

	function setMinBetPerTx(uint256 minBet) public {
		require(msg.sender == OWNER && minBet > 1000);

		MINBET_perTX = minBet;
	}

	function setMaxWin(uint8 newMaxWinInThousandthPercents) public {
		// cannot set bet limit greater than 5% of total BANKROLL.
		require(msg.sender == OWNER && newMaxWinInThousandthPercents <= 50);

		MAXWIN_inTHOUSANDTHPERCENTS = newMaxWinInThousandthPercents;
	}

	// rescue tokens inadvertently sent to the contract address 
	function ERC20Rescue(address tokenAddress, uint256 amtTokens) public {
		require (msg.sender == OWNER);

		ERC20(tokenAddress).transfer(msg.sender, amtTokens);
	}

	// require that the query time is too slow, bet has not been paid out, and either contract owner or player is calling this function.
	// this will only be used/can occur on queries that are forwarded to oraclize in the first place. All others will be paid out immediately.
	function refund(bytes32 oraclizeQueryId) public {
		// store data in memory for easy access.
		DiceGameData memory data = diceData[oraclizeQueryId];

		require(block.timestamp - data.start >= ORACLIZEQUERYMAXTIME
			&& (msg.sender == OWNER || msg.sender == data.player)
			&& (!data.paidOut)
			&& LIABILITIES >= data.etherReceived
			&& data.etherReceived > 0
			&& REFUNDSACTIVE);

		// set paidout == true, so users can't request more refunds, and a super delayed oraclize __callback will just get reverted
		diceData[oraclizeQueryId].paidOut = true;

		// subtract etherReceived because the bet is being refunded
		LIABILITIES = SafeMath.sub(LIABILITIES, data.etherReceived);

		// then transfer the original bet to the player.
		data.player.transfer(data.etherReceived);

		// finally, log an event saying that the refund has processed.
		emit Refund(oraclizeQueryId, data.etherReceived);
	}

	function play(uint256 betPerRoll, uint16 rolls, uint8 rollUnder) public payable {

		// store in memory for cheaper access
		uint256 minBetPerTx = MINBET_perTX;

		require(!GAMEPAUSED
				&& betPerRoll * rolls >= minBetPerTx
				&& msg.value >= minBetPerTx
				&& betPerRoll >= MINBET_perROLL
				&& rolls > 0
				&& rolls <= 1024
				&& betPerRoll <= msg.value
				&& rollUnder > 1
				&& rollUnder < 98
				// make sure that the player cannot win more than the max win (forget about house edge here)
				&& (SafeMath.mul(betPerRoll, 100) / (rollUnder - 1)) <= getMaxWin());

		// equation for gas to oraclize is:
		// gas = (some fixed gas amt) + 1005 * rolls

		uint256 gasToSend = INITIALGASFORORACLIZE + (uint256(1005) * rolls);

		EOSBetBankrollInterface(BANKROLLER).payOraclize(oraclize_getPrice('random', gasToSend));

		// oraclize_newRandomDSQuery(delay in seconds, bytes of random data, gas for callback function)
		bytes32 oraclizeQueryId = oraclize_newRandomDSQuery(0, 30, gasToSend);

		diceData[oraclizeQueryId] = DiceGameData({
			player : msg.sender,
			paidOut : false,
			start : block.timestamp,
			etherReceived : msg.value,
			betPerRoll : betPerRoll,
			rolls : rolls,
			rollUnder : rollUnder
		});

		// add the sent value into liabilities. this should NOT go into the bankroll yet
		// and must be quarantined here to prevent timing attacks
		LIABILITIES = SafeMath.add(LIABILITIES, msg.value);

		// log an event
		emit BuyRolls(oraclizeQueryId);
	}

	// oraclize callback.
	// Basically do the instant bet resolution in the play(...) function above, but with the random data 
	// that oraclize returns, instead of getting psuedo-randomness from block.blockhash 
	function __callback(bytes32 _queryId, string _result, bytes _proof) public {

		DiceGameData memory data = diceData[_queryId];
		// only need to check these, as all of the game based checks were already done in the play(...) function 
		require(msg.sender == oraclize_cbAddress() 
			&& !data.paidOut 
			&& data.player != address(0) 
			&& LIABILITIES >= data.etherReceived);

		// if the proof has failed, immediately refund the player his original bet...
		if (oraclize_randomDS_proofVerify__returnCode(_queryId, _result, _proof) != 0){

			if (REFUNDSACTIVE){
				// set contract data
				diceData[_queryId].paidOut = true;

				// if the call fails, then subtract the original value sent from liabilites and amount wagered, and then send it back
				LIABILITIES = SafeMath.sub(LIABILITIES, data.etherReceived);

				// transfer the original bet
				data.player.transfer(data.etherReceived);

				// log the refund
				emit Refund(_queryId, data.etherReceived);
			}
			// log the ledger proof fail
			emit LedgerProofFailed(_queryId);
			
		}
		// else, resolve the bet as normal with this miner-proof proven-randomness from oraclize.
		else {
			// save these in memory for cheap access
			uint8 houseEdgeInThousandthPercents = HOUSEEDGE_inTHOUSANDTHPERCENTS;

			// set the current balance available to the player as etherReceived
			uint256 etherAvailable = data.etherReceived;

			// logs for the frontend, as before...
			uint256[] memory logsData = new uint256[](4);

			// this loop is highly similar to the one from before. Instead of fully documented, the differences will be pointed out instead.
			uint256 winnings;
			uint16 gamesPlayed;

			// get this value outside of the loop for gas costs sake
			uint256 hypotheticalWinAmount = SafeMath.mul(SafeMath.mul(data.betPerRoll, 100), (1000 - houseEdgeInThousandthPercents)) / (data.rollUnder - 1) / 1000;

			while (gamesPlayed < data.rolls && etherAvailable >= data.betPerRoll){
				
				// now, this roll is keccak256(_result, nonce) + 1 ... this is the main difference from using oraclize.

				if (uint8(uint256(keccak256(_result, gamesPlayed)) % 100) + 1 < data.rollUnder){

					// now, just get the respective fields from data.field unlike before where they were in seperate variables.
					winnings = hypotheticalWinAmount;

					// assemble logs...
					if (gamesPlayed <= 255){
						logsData[0] += uint256(2) ** (255 - gamesPlayed);
					}
					else if (gamesPlayed <= 511){
						logsData[1] += uint256(2) ** (511 - gamesPlayed);
					}
					else if (gamesPlayed <= 767){
						logsData[2] += uint256(2) ** (767 - gamesPlayed);
					}
					else {
						logsData[3] += uint256(2) ** (1023 - gamesPlayed);
					}
				}
				else {
					//  leave 1 wei as a consolation prize :)
					winnings = 1;
				}
				gamesPlayed++;
				
				etherAvailable = SafeMath.sub(SafeMath.add(etherAvailable, winnings), data.betPerRoll);
			}

			// track that these games were played
			GAMESPLAYED += gamesPlayed;

			// and add the amount wagered
			AMOUNTWAGERED = SafeMath.add(AMOUNTWAGERED, SafeMath.mul(data.betPerRoll, gamesPlayed));

			// IMPORTANT: we must change the "paidOut" to TRUE here to prevent reentrancy/other nasty effects.
			// this was not needed with the previous loop/code block, and is used because variables must be written into storage
			diceData[_queryId].paidOut = true;

			// decrease LIABILITIES when the spins are made
			LIABILITIES = SafeMath.sub(LIABILITIES, data.etherReceived);

			// get the developers cut, and send the rest of the ether received to the bankroller contract
			uint256 developersCut = SafeMath.mul(SafeMath.mul(data.betPerRoll, houseEdgeInThousandthPercents), gamesPlayed) / 5000;

			// add the devs cut to the developers fund.
			DEVELOPERSFUND = SafeMath.add(DEVELOPERSFUND, developersCut);

			EOSBetBankrollInterface(BANKROLLER).receiveEtherFromGameAddress.value(SafeMath.sub(data.etherReceived, developersCut))();

			// force the bankroller contract to pay out the player
			EOSBetBankrollInterface(BANKROLLER).payEtherToWinner(etherAvailable, data.player);

			// log an event, now with the oraclize query id
			emit DiceLargeBet(_queryId, gamesPlayed, logsData[0], logsData[1], logsData[2], logsData[3]);
		}
	}

// END OF CONTRACT. REPORT ANY BUGS TO DEVELOPMENT@EOSBET.IO
// YES! WE _DO_ HAVE A BUG BOUNTY PROGRAM!

// THANK YOU FOR READING THIS CONTRACT, HAVE A NICE DAY :)

}