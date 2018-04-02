pragma solidity ^0.4.21;

import "./usingOraclize.sol";
import "./EOSBetBankroll.sol";
import "./SafeMath.sol";

contract EOSBetSlots is usingOraclize, EOSBetGameInterface {

	using SafeMath for *;

	// events
	event BuyCredits(bytes32 indexed oraclizeQueryId);
	event LedgerProofFailed(bytes32 indexed oraclizeQueryId);
	event Refund(bytes32 indexed oraclizeQueryId, uint256 amount);
	event SlotsLargeBet(bytes32 indexed oraclizeQueryId, uint256 data1, uint256 data2, uint256 data3, uint256 data4, uint256 data5, uint256 data6, uint256 data7, uint256 data8);
	event SlotsSmallBet(uint256 data1, uint256 data2, uint256 data3, uint256 data4, uint256 data5, uint256 data6, uint256 data7, uint256 data8);

	// slots game structure
	struct SlotsGameData {
		address player;
		bool paidOut;
		uint256 start;
		uint256 etherReceived;
		uint8 credits;
	}

	mapping (bytes32 => SlotsGameData) public slotsData;

	// ether in this contract can be in one of two locations:
	uint256 public LIABILITIES;
	uint256 public DEVELOPERSFUND;

	// counters for frontend statistics
	uint256 public AMOUNTWAGERED;
	uint256 public DIALSSPUN;
	
	// togglable values
	uint256 public ORACLIZEQUERYMAXTIME;
	uint256 public MINBET_perSPIN;
	uint256 public MINBET_perTX;
	uint256 public ORACLIZEGASPRICE;
	uint256 public INITIALGASFORORACLIZE;
	uint16 public MAXWIN_inTHOUSANDTHPERCENTS;

	// togglable functionality of contract
	bool public GAMEPAUSED;
	bool public REFUNDSACTIVE;

	// owner of contract
	address public OWNER;

	// bankroller address
	address public BANKROLLER;

	// constructor
	function EOSBetSlots() public {
		// ledger proof is ALWAYS verified on-chain
		oraclize_setProof(proofType_Ledger);

		// gas prices for oraclize call back, can be changed
		oraclize_setCustomGasPrice(8000000000);
		ORACLIZEGASPRICE = 8000000000;
		INITIALGASFORORACLIZE = 225000;

		AMOUNTWAGERED = 0;
		DIALSSPUN = 0;

		GAMEPAUSED = false;
		REFUNDSACTIVE = true;

		ORACLIZEQUERYMAXTIME = 6 hours;
		MINBET_perSPIN = 2 finney; // currently, this is ~40-50c a spin, which is pretty average slots. This is changeable by OWNER 
		MINBET_perTX = 10 finney;
        MAXWIN_inTHOUSANDTHPERCENTS = 333; // 333/1000 so a jackpot can take 33% of bankroll (extremely rare)
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
		// require that BANKROLLER address == 0x0 (address not set yet), and coming from owner.
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
	// and thne change the gas price using the proper oraclize function
	function setOraclizeQueryGasPrice(uint256 gasPrice) public {
		require(msg.sender == OWNER);

		ORACLIZEGASPRICE = gasPrice;
		oraclize_setCustomGasPrice(gasPrice);
	}

	// should be ~160,000 to save eth
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

	function setMinBetPerSpin(uint256 minBet) public {
		require(msg.sender == OWNER && minBet > 1000);

		MINBET_perSPIN = minBet;
	}

	function setMinBetPerTx(uint256 minBet) public {
		require(msg.sender == OWNER && minBet > 1000);

		MINBET_perTX = minBet;
	}

	function setMaxwin(uint16 newMaxWinInThousandthPercents) public {
		require(msg.sender == OWNER && newMaxWinInThousandthPercents <= 333); // cannot set max win greater than 1/3 of the bankroll (a jackpot is very rare)

		MAXWIN_inTHOUSANDTHPERCENTS = newMaxWinInThousandthPercents;
	}

	// rescue tokens inadvertently sent to the contract address 
	function ERC20Rescue(address tokenAddress, uint256 amtTokens) public {
		require (msg.sender == OWNER);

		ERC20(tokenAddress).transfer(msg.sender, amtTokens);
	}

	// this can be deleted after some testing.
	function emergencySelfDestruct() public {
		require(msg.sender == OWNER);

		selfdestruct(msg.sender);
	}

	function refund(bytes32 oraclizeQueryId) public {
		// save into memory for cheap access
		SlotsGameData memory data = slotsData[oraclizeQueryId];

		//require that the query time is too slow, bet has not been paid out, and either contract owner or player is calling this function.
		require(SafeMath.sub(block.timestamp, data.start) >= ORACLIZEQUERYMAXTIME
			&& (msg.sender == OWNER || msg.sender == data.player)
			&& (!data.paidOut)
			&& data.etherReceived <= LIABILITIES
			&& data.etherReceived > 0
			&& REFUNDSACTIVE);

		// set contract data
		slotsData[oraclizeQueryId].paidOut = true;

		// subtract etherReceived from these two values because the bet is being refunded
		LIABILITIES = SafeMath.sub(LIABILITIES, data.etherReceived);

		// then transfer the original bet to the player.
		data.player.transfer(data.etherReceived);

		// finally, log an event saying that the refund has processed.
		emit Refund(oraclizeQueryId, data.etherReceived);
	}

	function play(uint8 credits) public payable {
		// save for future use / gas efficiency
		uint256 betPerCredit = msg.value / credits;

		// require that the game is unpaused, and that the credits being purchased are greater than 0 and less than the allowed amount, default: 100 spins 
		// verify that the bet is less than or equal to the bet limit, so we don't go bankrupt, and that the etherreceived is greater than the minbet.
		require(!GAMEPAUSED
			&& msg.value >= MINBET_perTX
			&& betPerCredit >= MINBET_perSPIN
			&& credits > 0 
			&& credits <= 224
			&& SafeMath.mul(betPerCredit, 5000) <= getMaxWin()); // 5000 is the jackpot payout (max win on a roll)

		// equation for gas to oraclize is:
		// gas = (some fixed gas amt) + 3270 * credits

		uint256 gasToSend = INITIALGASFORORACLIZE + (uint256(3270) * credits);

		EOSBetBankrollInterface(BANKROLLER).payOraclize(oraclize_getPrice('random', gasToSend));

		// oraclize_newRandomDSQuery(delay in seconds, bytes of random data, gas for callback function)
		bytes32 oraclizeQueryId = oraclize_newRandomDSQuery(0, 30, gasToSend);

		// add the new slots data to a mapping so that the oraclize __callback can use it later
		slotsData[oraclizeQueryId] = SlotsGameData({
			player : msg.sender,
			paidOut : false,
			start : block.timestamp,
			etherReceived : msg.value,
			credits : credits
		});

		// add the sent value into liabilities. this should NOT go into the bankroll yet
		// and must be quarantined here to prevent timing attacks
		LIABILITIES = SafeMath.add(LIABILITIES, msg.value);

		emit BuyCredits(oraclizeQueryId);
	}

	function __callback(bytes32 _queryId, string _result, bytes _proof) public {
		// get the game data and put into memory
		SlotsGameData memory data = slotsData[_queryId];

		require(msg.sender == oraclize_cbAddress() 
			&& !data.paidOut 
			&& data.player != address(0) 
			&& LIABILITIES >= data.etherReceived);

		// if the proof has failed, immediately refund the player the original bet.
		if (oraclize_randomDS_proofVerify__returnCode(_queryId, _result, _proof) != 0){

			if (REFUNDSACTIVE){
				// set contract data
				slotsData[_queryId].paidOut = true;

				// subtract from liabilities and amount wagered, because this bet is being refunded.
				LIABILITIES = SafeMath.sub(LIABILITIES, data.etherReceived);

				// transfer the original bet back
				data.player.transfer(data.etherReceived);

				// log the refund
				emit Refund(_queryId, data.etherReceived);
			}
			// log the ledger proof fail 
			emit LedgerProofFailed(_queryId);
			
		}
		else {
			// again, this block is almost identical to the previous block in the play(...) function 
			// instead of duplicating documentation, we will just point out the changes from the other block 
			uint256 dialsSpun;
			
			uint8 dial1;
			uint8 dial2;
			uint8 dial3;
			
			uint256[] memory logsData = new uint256[](8);
			
			uint256 payout;
			
			// must use data.credits instead of credits.
			for (uint8 i = 0; i < data.credits; i++){

				// all dials now use _result, instead of blockhash, this is the main change, and allows Slots to 
				// accomodate bets of any size, free of possible miner interference 
				dialsSpun += 1;
				dial1 = uint8(uint(keccak256(_result, dialsSpun)) % 64);
				
				dialsSpun += 1;
				dial2 = uint8(uint(keccak256(_result, dialsSpun)) % 64);
				
				dialsSpun += 1;
				dial3 = uint8(uint(keccak256(_result, dialsSpun)) % 64);

				// dial 1
				dial1 = getDial1Type(dial1);

				// dial 2
				dial2 = getDial2Type(dial2);

				// dial 3
				dial3 = getDial3Type(dial3);

				// determine the payout
				payout += determinePayout(dial1, dial2, dial3);
				
				// assembling log data
				if (i <= 27){
					// in logsData0
					logsData[0] += uint256(dial1) * uint256(2) ** (3 * ((3 * (27 - i)) + 2));
					logsData[0] += uint256(dial2) * uint256(2) ** (3 * ((3 * (27 - i)) + 1));
					logsData[0] += uint256(dial3) * uint256(2) ** (3 * ((3 * (27 - i))));
				}
				else if (i <= 55){
					// in logsData1
					logsData[1] += uint256(dial1) * uint256(2) ** (3 * ((3 * (55 - i)) + 2));
					logsData[1] += uint256(dial2) * uint256(2) ** (3 * ((3 * (55 - i)) + 1));
					logsData[1] += uint256(dial3) * uint256(2) ** (3 * ((3 * (55 - i))));
				}
				else if (i <= 83) {
					// in logsData2
					logsData[2] += uint256(dial1) * uint256(2) ** (3 * ((3 * (83 - i)) + 2));
					logsData[2] += uint256(dial2) * uint256(2) ** (3 * ((3 * (83 - i)) + 1));
					logsData[2] += uint256(dial3) * uint256(2) ** (3 * ((3 * (83 - i))));
				}
				else if (i <= 111) {
					// in logsData3
					logsData[3] += uint256(dial1) * uint256(2) ** (3 * ((3 * (111 - i)) + 2));
					logsData[3] += uint256(dial2) * uint256(2) ** (3 * ((3 * (111 - i)) + 1));
					logsData[3] += uint256(dial3) * uint256(2) ** (3 * ((3 * (111 - i))));
				}
				else if (i <= 139){
					// in logsData4
					logsData[4] += uint256(dial1) * uint256(2) ** (3 * ((3 * (139 - i)) + 2));
					logsData[4] += uint256(dial2) * uint256(2) ** (3 * ((3 * (139 - i)) + 1));
					logsData[4] += uint256(dial3) * uint256(2) ** (3 * ((3 * (139 - i))));
				}
				else if (i <= 167){
					// in logsData5
					logsData[5] += uint256(dial1) * uint256(2) ** (3 * ((3 * (167 - i)) + 2));
					logsData[5] += uint256(dial2) * uint256(2) ** (3 * ((3 * (167 - i)) + 1));
					logsData[5] += uint256(dial3) * uint256(2) ** (3 * ((3 * (167 - i))));
				}
				else if (i <= 195){
					// in logsData6
					logsData[6] += uint256(dial1) * uint256(2) ** (3 * ((3 * (195 - i)) + 2));
					logsData[6] += uint256(dial2) * uint256(2) ** (3 * ((3 * (195 - i)) + 1));
					logsData[6] += uint256(dial3) * uint256(2) ** (3 * ((3 * (195 - i))));
				}
				else if (i <= 223){
					// in logsData7
					logsData[7] += uint256(dial1) * uint256(2) ** (3 * ((3 * (223 - i)) + 2));
					logsData[7] += uint256(dial2) * uint256(2) ** (3 * ((3 * (223 - i)) + 1));
					logsData[7] += uint256(dial3) * uint256(2) ** (3 * ((3 * (223 - i))));
				}
			}

			// track that these spins were made
			DIALSSPUN += dialsSpun;

			// and add the amount wagered
			AMOUNTWAGERED = SafeMath.add(AMOUNTWAGERED, data.etherReceived);

			// IMPORTANT: we must change the "paidOut" to TRUE here to prevent reentrancy/other nasty effects.
			// this was not needed with the previous loop/code block, and is used because variables must be written into storage
			slotsData[_queryId].paidOut = true;

			// decrease LIABILITIES when the spins are made
			LIABILITIES = SafeMath.sub(LIABILITIES, data.etherReceived);

			// get the developers cut, and send the rest of the ether received to the bankroller contract
			uint256 developersCut = data.etherReceived / 100;

			DEVELOPERSFUND = SafeMath.add(DEVELOPERSFUND, developersCut);

			EOSBetBankrollInterface(BANKROLLER).receiveEtherFromGameAddress.value(SafeMath.sub(data.etherReceived, developersCut))();

			// get the ether to be paid out, and force the bankroller contract to pay out the player
			uint256 etherPaidout = SafeMath.mul((data.etherReceived / data.credits), payout);

			EOSBetBankrollInterface(BANKROLLER).payEtherToWinner(etherPaidout, data.player);

			// log en event with indexed query id
			emit SlotsLargeBet(_queryId, logsData[0], logsData[1], logsData[2], logsData[3], logsData[4], logsData[5], logsData[6], logsData[7]);
		}
	}
	
	// HELPER FUNCTIONS TO:
	// calculate the result of the dials based on the hardcoded slot data: 

	// STOPS			REEL#1	REEL#2	REEL#3
	///////////////////////////////////////////
	// gold ether 	0 //  1  //  3   //   1  //	
	// silver ether 1 //  7  //  1   //   6  //
	// bronze ether 2 //  1  //  7   //   6  //
	// gold planet  3 //  5  //  7   //   6  //
	// silverplanet 4 //  9  //  6   //   7  //
	// bronzeplanet 5 //  9  //  8   //   6  //
	// ---blank---  6 //  32 //  32  //   32 //
	///////////////////////////////////////////

	// note that dial1 / 2 / 3 will go from mod 64 to mod 7 in this manner
	
	function getDial1Type(uint8 dial1Location) internal pure returns(uint8) {
	    if (dial1Location == 0) 							        { return 0; }
		else if (dial1Location >= 1 && dial1Location <= 7) 			{ return 1; }
		else if (dial1Location == 8) 						        { return 2; }
		else if (dial1Location >= 9 && dial1Location <= 13) 		{ return 3; }
		else if (dial1Location >= 14 && dial1Location <= 22) 		{ return 4; }
		else if (dial1Location >= 23 && dial1Location <= 31) 		{ return 5; }
		else 										                { return 6; }
	}
	
	function getDial2Type(uint8 dial2Location) internal pure returns(uint8) {
	    if (dial2Location >= 0 && dial2Location <= 2) 				{ return 0; }
		else if (dial2Location == 3) 						        { return 1; }
		else if (dial2Location >= 4 && dial2Location <= 10)			{ return 2; }
		else if (dial2Location >= 11 && dial2Location <= 17) 		{ return 3; }
		else if (dial2Location >= 18 && dial2Location <= 23) 		{ return 4; }
		else if (dial2Location >= 24 && dial2Location <= 31) 		{ return 5; }
		else 										                { return 6; }
	}
	
	function getDial3Type(uint8 dial3Location) internal pure returns(uint8) {
	    if (dial3Location == 0) 							        { return 0; }
		else if (dial3Location >= 1 && dial3Location <= 6)			{ return 1; }
		else if (dial3Location >= 7 && dial3Location <= 12) 		{ return 2; }
		else if (dial3Location >= 13 && dial3Location <= 18)		{ return 3; }
		else if (dial3Location >= 19 && dial3Location <= 25) 		{ return 4; }
		else if (dial3Location >= 26 && dial3Location <= 31) 		{ return 5; }
		else 										                { return 6; }
	}
	
	// HELPER FUNCTION TO:
	// determine the payout given dial locations based on this table
	
	// hardcoded payouts data:
	// 			LANDS ON 				//	PAYS  //
	////////////////////////////////////////////////
	// Bronze E -> Silver E -> Gold E	//	5000  //
	// 3x Gold Ether					//	1777  //
	// 3x Silver Ether					//	250   //
	// 3x Bronze Ether					//	250   //
	//  3x any Ether 					//	95    //
	// Bronze P -> Silver P -> Gold P	//	90    //
	// 3x Gold Planet 					//	50    //
	// 3x Silver Planet					//	25    //
	// Any Gold P & Silver P & Bronze P //	20    //
	// 3x Bronze Planet					//	10    //
	// Any 3 planet type				//	3     //
	// Any 3 gold						//	3     //
	// Any 3 silver						//	2     //
	// Any 3 bronze						//	2     //
	// Blank, blank, blank				//	1     //
	// else								//  0     //
	////////////////////////////////////////////////
	
	function determinePayout(uint8 dial1, uint8 dial2, uint8 dial3) internal pure returns(uint256) {
		if (dial1 == 6 || dial2 == 6 || dial3 == 6){
			// all blank
			if (dial1 == 6 && dial2 == 6 && dial3 == 6)
				return 1;
		}
		else if (dial1 == 5){
			// bronze planet -> silver planet -> gold planet
			if (dial2 == 4 && dial3 == 3) 
				return 90;

			// one gold planet, one silver planet, one bronze planet, any order!
			// note: other order covered above, return 90
			else if (dial2 == 3 && dial3 == 4)
				return 20;

			// all bronze planet 
			else if (dial2 == 5 && dial3 == 5) 
				return 10;

			// any three planet type 
			else if (dial2 >= 3 && dial2 <= 5 && dial3 >= 3 && dial3 <= 5)
				return 3;

			// any three bronze 
			else if ((dial2 == 2 || dial2 == 5) && (dial3 == 2 || dial3 == 5))
				return 2;
		}
		else if (dial1 == 4){
			// all silver planet
			if (dial2 == 4 && dial3 == 4)
				return 25;

			// one gold planet, one silver planet, one bronze planet, any order!
			else if ((dial2 == 3 && dial3 == 5) || (dial2 == 5 && dial3 == 3))
				return 20;

			// any three planet type 
			else if (dial2 >= 3 && dial2 <= 5 && dial3 >= 3 && dial3 <= 5)
				return 3;

			// any three silver
			else if ((dial2 == 1 || dial2 == 4) && (dial3 == 1 || dial3 == 4))
				return 2;
		}
		else if (dial1 == 3){
			// all gold planet
			if (dial2 == 3 && dial3 == 3)
				return 50;

			// one gold planet, one silver planet, one bronze planet, any order!
			else if ((dial2 == 4 && dial3 == 5) || (dial2 == 5 && dial3 == 4))
				return 20;

			// any three planet type 
			else if (dial2 >= 3 && dial2 <= 5 && dial3 >= 3 && dial3 <= 5)
				return 3;

			// any three gold
			else if ((dial2 == 0 || dial2 == 3) && (dial3 == 0 || dial3 == 3))
				return 3;
		}
		else if (dial1 == 2){
			if (dial2 == 1 && dial3 == 0)
				return 5000; // jackpot!!!!

			// all bronze ether
			else if (dial2 == 2 && dial3 == 2)
				return 250;

			// all some type of ether
			else if (dial2 >= 0 && dial2 <= 2 && dial3 >= 0 && dial3 <= 2)
				return 95;

			// any three bronze
			else if ((dial2 == 2 || dial2 == 5) && (dial3 == 2 || dial3 == 5))
				return 2;
		}
		else if (dial1 == 1){
			// all silver ether 
			if (dial2 == 1 && dial3 == 1)
				return 250;

			// all some type of ether
			else if (dial2 >= 0 && dial2 <= 2 && dial3 >= 0 && dial3 <= 2)
				return 95;

			// any three silver
			else if ((dial2 == 1 || dial2 == 4) && (dial3 == 1 || dial3 == 4))
				return 3;
		}
		else if (dial1 == 0){
			// all gold ether
			if (dial2 == 0 && dial3 == 0)
				return 1777;

			// all some type of ether
			else if (dial2 >= 0 && dial2 <= 2 && dial3 >= 0 && dial3 <= 2)
				return 95;

			// any three gold
			else if ((dial2 == 0 || dial2 == 3) && (dial3 == 0 || dial3 == 3))
				return 3;
		}
		return 0;
	}

}