# WELCOME TO EOSBet.IO!!!

## This is the directory for our Ethereum Gambling contracts.

### We are currently running a bug bounty, please see the Reddit thread:

#### Here is a quick description of our gambling system:

Our contract system is fairly simple. There are 3 main contracts, `EOSBetBankroll.sol`, `EOSBetSlots.sol`, and `EOSBetDice.sol`.

The bankroll contract is in charge of holding all the funds for the games. 

The games are in charge of taking bets, and interacting with the bankroll contract to payout players, and to receive the players losses.

Randomness generation is an important part of any gambling contractm, and we are proud of our approach towards getting provable randomness. We are assuming you are familiar with the classic argument against getting randomness from `block.blockhash(block.number)`, because a miner could "throw away" a block that does not grant the miner a win, and try and mine a new block (and take the small loss by sumbitting an uncle, later, if the miner does not mine a new block). We have ran some python simulations, and can verify that we are at a risk of miner cheating for bets >=0.35 Ether.

Therefore, our solution is simple. For small bets <0.35 Ether, we simply use `block.blockhash(block.number)` to get randomness. Doing this, we get a faster turn around on bets, and we don't have to pay an oraclize.it fee for off-chain randomness.

However, for larger bets, we must be careful against miner cheating. For bets >=0.35 Ether, we use oraclize.it's random-datasource call, and then resolve the bet when they call our `__callback()` function.

Another problem, with current on-chain gambling offerings, is the fact that Ethereum transactions are pretty slow, and unfortunately there's no way of getting around slow transacions. However, we allow bettors to "pre-purchase" up to 224 spins for slots, and 1024 rolls for dice. They then just have to wait for 1 transaction to resolve, and then get to use our pretty front end (work-in-progress) to resolve the bets, and have fun gambling!

Again, the bankroll is used to payout players, and pay for any oraclize fees that will be charged to the Dice or Slots contract.

Also, the bankroll can be used by **ANYONE** to deposit money, and *stake* our games with Ether, receiving dividends from the small house edge that is in our games. Depositing money will result in receiving EOSBetStakeTokens in proportion to how much money a user deposited into the bankroll. There is a variable amount of time `WAITTIMEUNTILWITHDRAWORTRANSFER` that their Ether must be "staked" for, and then they are free to `cashoutEOSBetStakeTokens()` with the amount of tokens that they wish to cashout. The amount of tokens they wish to cash out are compared with the "global" supply of tokens, which then is used to determine what proportion of Ether they own, which is then sent to them.

The EOSBetStakeTokens are *soley* accounting tokens, and don't have any value outside of our contracts. However, since ERC20 tokens are clearly all the rage right now, we decided to make EOSBetStakeTokens ERC20 compatible, because why not? :)

Also, note that 20% of the profit of the games, and 1% of withdrawals from the bankroll will be sent to the `DEVELOPERSFUND` so that we can fund marketing, more games, and etc.

Finally, note that everything is supposed to be trustless in the game contracts. Bankrollers should be able to deposit and stake the games trustlessly, and gamblers should be able to play a fair game, also trustlessly. Besides general functionality like pausing the games, changing some parameters, the developers shouldn't have much power in these contracts. **NOTE** that we cannot add new games! This is purposeful, because we could just add a game called `DeveloperAlwaysWins.sol` and then drain the bankroll. That wouldn't be fun.

Yes, we will take out the `emergencySelfDestruct()` function when entering production. No, this is not a bug that can be caught in our bug bounty program.


#### Now lets dive a little deeper into our contracts:

##### EOSBetDice.sol & EOSBetSlots.sol

All games must follow the `contract EOSBetGameInterface{}` interface contract. This is as follows:

```
contract EOSBetGameInterface {
	uint256 public DEVELOPERSFUND;
	uint256 public LIABILITIES;
	function payDevelopersFund(address developer) public;
	function receivePaymentForOraclize() payable public;
	function getMaxWin() public view returns(uint256);
}
```

First, we have the `DEVELOPERSFUND`. 20% of the game profit will increment this fund. This is taken by `betSize * numberOfBets * houseEdge * 20%`. T

Second, we have the `LIABILITIES`. All large bets will initially increment the liabilities when forwarding the randomness call to oraclize.it. When oraclize calls back, `LIABILITIES` will decrement, and the bet is treated like a normal bet.

`payDevelopersFund(address developer)` can only be called by the BANKROLLER contract, which can only be called by OWNER. This just sends the developers fund to a specified address, and then sets the fund equal to zero.

`receivePaymentForOraclize() payable` is in charge of receiving ether from the bankroll, equivalent to the fee + gas * gasPrice that oraclize is charging.

`getMaxWin() view` is a function that asks the BANKROLLER contract to see how much investment there is in the bankroll, and then determines the maximum win size, that a bettor can win. We don't want to accept too large of bets and go bankrupt!!

##### EOSBetDice.sol

We start off with a bunch of owner only functions to change parameters to the games. Dangerous parameters have a cap on them, that even the owner cannot go above when he is calling the functions. Pretty straightforward...

Again, we have a suicide/selfdestruct function, this will be taken out for production, and is only for testing!

`refund(bytes32 oraclizeQueryId)` is meant to be called by either the player or the owner, if the oraclize query is taking too long to `__callback`. This can be a (rare) problem with oraclize, and we want people to be able to retreive their funds if oraclize is slow/fails to callback.

`play(uint256 betPerRoll, uint16 rolls, uint8 rollUnder) payable` is the main function in this contract. Players are allowed to specify the amount of bet for each roll of dice, the total number of rolls, and the number that they are trying to roll under. (Ex: a choice of 77 means that 1-76 are the winning numbers, and 77-100 are losers!)

After doing necessary checks, the game has two options. If the `betPerRoll < MINBET_forORACLIZE` then the roll is resolved using `block.blockhash(block.number)`.

If not, then the bet infomation will be saved `SSTORE` and then oraclize will be called to supply randomness, to resolve the bet safely.

After this point, the `__callback()` function and the `play()` function behave similarly.

A while loop starts, `while (gamesPlayed < rolls && etherAvailable >= betPerRoll)` where either every single roll will resolve as specified by the player, *or* the player will go bankrupt. 

A winning roll will credit based on the roll under number according to the standard dice formula: `hypotheticalWinAmount = SafeMath.mul(SafeMath.mul(betPerRoll, 100), (1000 - houseEdgeInThousandthPercents)) / (rollUnder - 1) / 1000;`

Once either all rolls resolve, or the player doesn't have the funds to play another roll, then the bankroll will receive the initial captial used to bet (subtracting from `LIABILITIES` if this is in the `__callback`), and the bankroll will send any winnings to the player. The wins are sent **SAFELY** by using msg.sender.send(amt), and catching failures. If a .send() fails, then the amount gets sent to the OWNER instead. We could have implemented some sort of fund recovery fairly easily, but decided to just not allow external contracts (with excessive logic in `function () payable`) to call our contracts. If you MUST call our gaming contracts with an external contract with a bunch of fallback logic, you are clearly doing something sketchy, and can contact us to recover your funds :)

Lastly, we must log some events so that the frontend knows what happened to the dice game. Logs can get expensive, so we did this the cheapest way. The frontend really just needs to know whether the player one or lost a game, so we can represent each game result using binary. (Ex: 10011 = win, loss, loss, win, win). 

In the `__callback` function, it is basically the same gameplay. However, note that we check the oraclize ledger proof to return `0` as required. If the oraclize proof fails, then we just refund the player immediately. Clearly, there is an issue where oraclize could chose to only (correcly) `__callback` if they are going to win, and just make the ledger proof fail if they lose. However, other gambling contracts put vastly more trust into oraclize than we do (where they could just outright win every single game) so we have decided to give them the benefit of the doubt here.

**However**, if we feel that oraclize is cheating (will be easily detectable), then we can just toggle off `REFUNDSACTIVE`. We would like to keep them on, of course, so that our players have a better experience. :)

##### EOSBetSlots.sol

Slots is a *very* similar contract, of course, and just about everything that was said about dice, also applies to slots. However, the gameplay is obviously different, and more complex.

Here, the `play(uint8 credits) payable` function only takes 1 argument, `credits`, and the amount bet per credit will just be `msg.value / credits`. Again, we do the necessary checks, and either forward to oraclize, or resolve in-house. The vast majority of bets for slots will be resolved in house, because it will take a large bankroll (and some really aggressive playing) to take the `betPerSpin >= 0.35 ether` so that oraclize must be called (this is because out jackpot is so large, at 5000x and we **must** be able to pay out the jackpot, and not go bankrupt, of course.)

There are 64 positions on the slots dial, and given the combinations, and their payouts, we have a 4.9% house edge, which is **very** generous. The standard casino does something between 15%-25% on slots, which is absolutely brutal.

There we loop though all the credits, find the payout given each combination, and then log the events for the front end. The logs are minimalistic, again, because they can get costly. Since there are 7 different items on the dial, we can store each dial in a uint4. The frontend then parses these hex-encoded logs into octal notation, and then gets the dial locations and replays the spins to our bettors! (Please stay tuned for the actual games, another 2-3 weeks, we promise!)

**positions for slots**
```
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
```

**payouts for slots**
```
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
```

There are found in our code too, for easy reference.

##### EOSBetBankroll.sol

The bankroll is in charge of all payouts, like the cashier at a casino. 

We have `payEtherToWinner(uint256 amtEther, address winner)` which safely sends ether to the winner. Again, we do not support calling our contracts with external contracts (with a lot of `function () playable` logic), so if your send fails, you will have to retreive the money from us, the OWNER. The function can only be called by a game contract, that get specified at initialization.

We have `receiveEtherFromGameAddress() payable` which is the function that the game contracts call when sending the bet ether to the bankroll. The function can only be called by a game contract, that get specified at initialization.

`payOraclize(uint256 amountToPay)` will send any amount to a game contract that calls this function. The game contracts calculate how much ether is going to be needed from oraclize, and then call this function to get the money from the BANKROLLER. The function can only be called by a game contract, that get specified at initialization.

Our fallback function `function () public payable` is the way that users can stake our bankroll. They can send any amount of ether to our contract, and receive a proportional amount of accounting tokens. There is a cap on the amount that can be contributed, denoted by `MAXIMUMINVESTMENTSALLOWED` however this can be raised and lowered by the OWNER. If our contracts catch fire, we might want to limit deposits, so it doesn't get too out of hand ;)

Extra ether, that is deposited over `MAXIMUMINVESTMENTSALLOWED` will be refunded to the investor in the same function call.

Players can cash out using `cashoutEOSBetStakeTokens(uint256 _amountTokens)`. They just specify the amount of tokens they want to cash out, these tokens are burned and removed from total supply, and then they will receive a proportional amount of ether. Hopefully, if our games do well, they will receive some extra ether due to the house edge. If we have a lot of bettors, we can see being a bankroll backed will be quite lucrative, but no promises!

`cashoutEOSBetStakeTokens_ALL()` just fully divests a player from the bankroll. This is nice because users can just send 0 ether to our contract, with extra data `0x7a09588b` to fully divest right away. They don't need to use our frontend at all, and can just MEW with a hardware wallet for safety! Still waiting on that Ledger <-> MetaMask integration... ;)

Note that there is a required stake time that users must leave their funds locked into the bankroll for. This will intially be only a few hours, but could get up to 10 weeks maximum (unlikely). Also, 1% of withdrawals will be given to developers for marketing reasons!

`withdrawDevelopersFund(address receiver)` tells DICE and SLOTS to give their `DEVELOPERSFUND` to a specified address. It also has the bankroll give any accumulated `DEVELOPERSFUND` to the same address, and then zeros out all these counters on all the contracts.


After this, is just basic ERC20 functionality. We do not allow users to transfer tokens until their locktime is up, or it would be too difficult to keep track of which tokens are not allowed to be cashed out. We also do not allow transfers to address(this) because it will just burn tokens. ALL ERC20 CONTRACTS NEED TO START DOING THIS, TOO MANY TOKENS GET WASTED!

###### usingOraclize.sol

This is the standard oraclize contract, and is out of scope of this bug bounty. But, if there are issues you find, definitely bring it up with the oraclize team, I'm sure they have a much larger bounty than I could afford!

##### SafeMath.sol

This is standard Zeppelin SafeMath, again, issues should be brought up with the Zeppelin team!

##### END

This is the end of the contract descriptions, please see this reddit thread for more details about our audit, we have some generous payouts!

Please submit any issues to our GitHub, and feel free to contact development@EOSBet.IO with any issues.

If you are privacy centric, please use our PGP Key below. We will also payout our bug bounty in Monero, if desired.

Cheers!
EOSBet.IO


```
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
iBNTpi4g5EPO
=/tgd
-----END PGP PUBLIC KEY BLOCK-----

```



