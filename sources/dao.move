module dao::contract {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::sui::SUI;
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use std::vector;

    // Errors
    const EWrongDao: u64 = 9;
    const EDaoBalanceNotEnough: u64 = 10;
    const EAccountSharesNotSufficient: u64 = 11;
    const EAlreadyVoted: u64 = 12;
    const EVotingEnded: u64 = 13;
    const EVotingNotEnded: u64 = 14;

    // Dao data
    struct Dao has key {
        id: UID,
        totalShares: Balance<SUI>,
        lockedFunds: u64,
        availableFunds: u64,
        members: u32,
        quorum: u64,
        voteTime: u64,
    }

    // Proposal data
    struct Proposal has key, store {
        id: UID,
        daoId: ID,
        amount: u64,
        recipient: address,
        votes: u64,
        voters: vector<address>,
        ends: u64,
        executed: bool,
        ended: bool,
    }

    // AccountCap for dao members
    struct AccountCap has key, store {
        id: UID,
        daoId: ID,
        shares: u64
    }

    fun init(ctx: &mut TxContext) {
        // set quorum to 70;
        let quorum: u64 = 70;
        // set voteTime to 5 minutes in miliseconds;
        let voteTime : u64= 5 * 60 * 1000;

        // populate the dao
        let dao = Dao {
            id: object::new(ctx),
            totalShares: balance::zero(),
            lockedFunds: 0,
            availableFunds: 0,
            members: 0,
            quorum,
            voteTime,
        };

        // allow everyone to be able to acces the dao
        transfer::share_object(dao);    
    }

    public fun joinDao(dao: &mut Dao, amount: Coin<SUI>, ctx: &mut TxContext): AccountCap {
        // get the dao id
        let daoId = object::uid_to_inner(&dao.id);

        // get shares amount
        let shares = coin::value(&amount);

        // add the amount to the dao total shares
        let coin_balance = coin::into_balance(amount);
        balance::join(&mut dao.totalShares, coin_balance);

        // next update the available shares
        let prevAvailableFunds = &dao.availableFunds;
        dao.availableFunds = *prevAvailableFunds + shares;

        // increase the member count
        let oldCount = &dao.members;
        dao.members = *oldCount + 1;

        let accountCap = AccountCap {
            id: object::new(ctx),
            daoId,
            shares
        };

        accountCap
    }   

    public fun increaseShares(dao: &mut Dao, accountCap: &mut AccountCap, amount: Coin<SUI>, _ctx: &mut TxContext): u64 {
        // check that user passes in the correct objects
        assert!(&accountCap.daoId == object::uid_as_inner(&dao.id), EWrongDao);

        // get shares amount
        let shares = coin::value(&amount);

        // add the amount to the dao total shares
        let coin_balance = coin::into_balance(amount);
        balance::join(&mut dao.totalShares, coin_balance);

        // next update the available shares
        let prevAvailableFunds = &dao.availableFunds;
        dao.availableFunds = *prevAvailableFunds + shares;

        // get the old shares
        let prevShares = &accountCap.shares;
        accountCap.shares = *prevShares + shares;

        accountCap.shares
    } 

    public fun redeemShares(dao: &mut Dao, accountCap: &mut AccountCap, amount: u64, ctx: &mut TxContext): Coin<SUI> {
        // check that user passes in the correct objects
        assert!(&accountCap.daoId == object::uid_as_inner(&dao.id), EWrongDao);

        // check that user has enough shares
        assert!(accountCap.shares >= amount, EAccountSharesNotSufficient);

        // check that there are available shares to complete the transaction
        assert!(dao.availableFunds >= amount, EDaoBalanceNotEnough);

        // next update the available shares
        let prevAvailableFunds = &dao.availableFunds;
        dao.availableFunds = *prevAvailableFunds - amount;

        // get the old shares
        let prevShares = &accountCap.shares;
        accountCap.shares = *prevShares - amount;

        // wrap balance with coin
        let redeemedShares = coin::take(&mut dao.totalShares, amount, ctx);
        redeemedShares
    }   

    public fun createProposal(dao: &mut Dao, accountCap: &mut AccountCap, amount: u64, recipient: address, clock: &Clock, ctx: &mut TxContext) {
        // check that user passes in the right objects
        assert!(&accountCap.daoId == object::uid_as_inner(&dao.id), EWrongDao);

        // check that there are available shares to complete the transaction
        assert!(dao.availableFunds >= amount, EDaoBalanceNotEnough);

        // get the dao id
        let daoId = object::uid_to_inner(&dao.id);

        // get time
        let ends = clock::timestamp_ms(clock) + dao.voteTime;

        // generate proposal
        let proposal = Proposal {
            id: object::new(ctx),
            daoId,
            amount,
            recipient,
            votes: 0,
            voters: vector::empty(),
            ends,
            executed: false,
            ended: false,
        };

        transfer::share_object(proposal);

        // next lock funds
        let prevAvailableFunds = &dao.availableFunds;
        dao.availableFunds = *prevAvailableFunds - amount;

        let prevLockedFunds = &dao.lockedFunds;
        dao.lockedFunds = *prevLockedFunds + amount;
    }

    public fun voteProposal(dao: &mut Dao, accountCap: &mut AccountCap, proposal: &mut Proposal, clock: &Clock, ctx: &mut TxContext): u64 {
        // check that user passes in the right objects
        assert!(&accountCap.daoId == object::uid_as_inner(&dao.id), EWrongDao);
        assert!(&proposal.daoId == object::uid_as_inner(&dao.id), EWrongDao);

        // check that time for voting has not elasped
        assert!(proposal.ends > clock::timestamp_ms(clock), EVotingEnded);

        // check that user has not voted;
        assert!(!vector::contains(&proposal.voters, &tx_context::sender(ctx)), EAlreadyVoted);

        // update proposal votes
        let prevVotes = &proposal.votes;
        proposal.votes = *prevVotes + accountCap.shares;

        vector::push_back(&mut proposal.voters,tx_context::sender(ctx));

        proposal.votes
    }

    public fun executeProposal(dao: &mut Dao, accountCap: &mut AccountCap, proposal: &mut Proposal, clock: &Clock, ctx: &mut TxContext): (bool, Coin<SUI>) {
        // check that user passes in the correct objects
        assert!(&accountCap.daoId == object::uid_as_inner(&dao.id), EWrongDao);
        assert!(&proposal.daoId == object::uid_as_inner(&dao.id), EWrongDao);

        // check that voting time has elapsed
        assert!(proposal.ends < clock::timestamp_ms(clock), EVotingNotEnded);

        // calculate voting result based on total sahres
        let amountTotalShares = balance::value(&dao.totalShares);
        let result = proposal.votes / amountTotalShares * 100;

        // set dao as ended
        proposal.ended = true;

        // unlock funds
        dao.lockedFunds = dao.lockedFunds - proposal.amount;

        if (result >= dao.quorum ){
            // set proposal as executed
            proposal.executed = true;
            
            // get payment coin
            let payment = coin::take(&mut dao.totalShares, proposal.amount, ctx);
            
            // return result
            (true, payment)
        }else{
           // release funds back to available funds
            dao.availableFunds = dao.availableFunds + proposal.amount;

            // create empty coin
            let nullCoin = coin::from_balance(balance::zero(), ctx);

            // return result
            (false, nullCoin)
        }
    }
}
