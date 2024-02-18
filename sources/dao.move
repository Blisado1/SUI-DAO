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

    fun create_dao(ctx: &mut TxContext) {
        // set quorum to 70;
        let quorum: u64 = 70;

        // set voteTime to 100 ticks;
        let voteTime : u64= 100;

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

    fun init(ctx: &mut TxContext) {
        create_dao(ctx);
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

    public fun increaseShares(dao: &mut Dao, accountCap: &mut AccountCap, amount: Coin<SUI>, _ctx: &mut TxContext) {
        // check that user passes in the right objects
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
    } 

    public fun redeemShares(dao: &mut Dao, accountCap: &mut AccountCap, amount: u64, ctx: &mut TxContext): Coin<SUI> {
        // check that user passes in the right objects
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

    public fun voteProposal(dao: &mut Dao, accountCap: &mut AccountCap, proposal: &mut Proposal, clock: &Clock, ctx: &mut TxContext) {
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
    }

    public fun executeProposal(dao: &mut Dao, accountCap: &mut AccountCap, proposal: &mut Proposal, clock: &Clock, ctx: &mut TxContext): (bool, Coin<SUI>) {
        // check that user passes in the right objects
        assert!(&accountCap.daoId == object::uid_as_inner(&dao.id), EWrongDao);
        assert!(&proposal.daoId == object::uid_as_inner(&dao.id), EWrongDao);

        // check that time for voting has elasped
        assert!(proposal.ends < clock::timestamp_ms(clock), EVotingNotEnded);

        // calculate voting result
        let amountTotalShares = balance::value(&dao.totalShares);

        let result = (proposal.votes / amountTotalShares) * 100;

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

    public fun getAccountShares(accountCap: &AccountCap): u64 {
        accountCap.shares
    }

    public fun getDaoTotalShares(dao: &Dao): u64 {
        balance::value(&dao.totalShares)
    }

    public fun getDaoLockedFunds(dao: &Dao): u64 {
        dao.lockedFunds
    }

    public fun getDaoAvailableFunds(dao: &Dao): u64 {
        dao.availableFunds
    }

    public fun getProposalVotes(proposal: &Proposal): u64 {
        proposal.votes
    }

    // TESTS
    #[test_only] use sui::test_scenario as ts;
    #[test_only] const USER1: address = @0xA;
    #[test_only] const USER2: address = @0xB;
    #[test_only] const USER3: address = @0xC;

    #[test_only]
    /// Wrapper of module initializer for testing
    public fun test_init(ctx: &mut TxContext) {
        create_dao(ctx);
    }

    #[test_only]
    public fun test_join_dao(ts: &mut ts::Scenario, sender: address, amountToDeposit: u64){
        ts::next_tx(ts, sender);

        // get dao
        let dao: Dao = ts::take_shared(ts);

        // mint tokens
        let coin = coin::mint_for_testing<SUI>(amountToDeposit, ts::ctx(ts));

        // get account cap
        let accountCap = joinDao(&mut dao, coin, ts::ctx(ts));

        // transfer account cap to user
        transfer::public_transfer(accountCap, sender);

        // return dao
        ts::return_shared(dao);
    }

    #[test_only]
    public fun test_increase_shares(ts: &mut ts::Scenario, sender: address, amountToDeposit: u64){
        ts::next_tx(ts, sender);

        // get dao
        let dao: Dao = ts::take_shared(ts);

        // get account 
        let accountCap = ts::take_from_sender<AccountCap>(ts);

        // mint tokens
        let coin = coin::mint_for_testing<SUI>(amountToDeposit, ts::ctx(ts));

        // increment shares
        increaseShares(&mut dao, &mut accountCap, coin, ts::ctx(ts));

        // return to sender
        ts::return_to_sender(ts, accountCap);

        // return dao
        ts::return_shared(dao);
    }

    #[test_only]
    public fun test_redeem_shares(ts: &mut ts::Scenario, sender: address, amountToRedeem: u64){
        ts::next_tx(ts, sender);

        // get dao
        let dao: Dao = ts::take_shared(ts);

        // get account 
        let accountCap = ts::take_from_sender<AccountCap>(ts);

        // redeem shares
        let coin = redeemShares(&mut dao, &mut accountCap, amountToRedeem, ts::ctx(ts));

        // transfer amount
        transfer::public_transfer(coin, sender);

        // return to sender
        ts::return_to_sender(ts, accountCap);

        // return dao
        ts::return_shared(dao);
    }

    #[test_only]
    public fun test_create_proposal(ts: &mut ts::Scenario, sender: address, amount: u64, recipient: address, clock: &Clock){
        ts::next_tx(ts, sender);

        // get dao
        let dao = ts::take_shared<Dao>(ts);

        // get account 
        let accountCap = ts::take_from_sender<AccountCap>(ts);

        // create proposal
        createProposal(&mut dao, &mut accountCap, amount, recipient, clock, ts::ctx(ts));

        // return to sender
        ts::return_to_sender(ts, accountCap);

        // return dao
        ts::return_shared(dao);
    }

    #[test_only]
    public fun test_vote_proposal(ts: &mut ts::Scenario, sender: address, clock: &Clock){
        ts::next_tx(ts, sender);

        // get dao
        let dao: Dao = ts::take_shared<Dao>(ts);

        // get account 
        let accountCap = ts::take_from_sender<AccountCap>(ts);

        // get proposal
        let proposal = ts::take_shared<Proposal>(ts);

        // create proposa
        voteProposal(&mut dao, &mut accountCap, &mut proposal, clock, ts::ctx(ts));

        // return to sender
        ts::return_to_sender(ts, accountCap);

        // return dao
        ts::return_shared<Dao>(dao);

        // return proposal
        ts::return_shared<Proposal>(proposal);
    }

    #[test_only]
    public fun test_execute_proposal(ts: &mut ts::Scenario, sender: address, clock: &Clock){
        ts::next_tx(ts, sender);

        // get dao
        let dao: Dao = ts::take_shared<Dao>(ts);

        // get account 
        let accountCap = ts::take_from_sender<AccountCap>(ts);

        // get proposal
        let proposal = ts::take_shared<Proposal>(ts);

        // execute proposal
        let (success, amount) = executeProposal(&mut dao, &mut accountCap, &mut proposal, clock, ts::ctx(ts));

        let value = coin::value(&amount);

        // check if proposal is successful
        assert!(success, 1);

        // check if amount is proposal amount
        assert!(value == proposal.amount, 1);

        transfer::public_transfer(amount, proposal.recipient);

        // return to sender
        ts::return_to_sender(ts, accountCap);

        // return dao
        ts::return_shared<Dao>(dao);

        // return proposal
        ts::return_shared<Proposal>(proposal);
    }


    #[test_only]
    public fun test_check_proposal_votes(ts: &mut ts::Scenario, amountToCheck: u64){
        ts::next_tx(ts, @0x0);

        // get dao
        let proposal = ts::take_shared<Proposal>(ts);

        assert!(getProposalVotes(&proposal) == amountToCheck, 2);

        // return dao
        ts::return_shared<Proposal>(proposal);
    }

    #[test_only]
    public fun test_check_dao_shares(ts: &mut ts::Scenario, amountToCheck: u64){
        ts::next_tx(ts, @0x0);

        // get dao
        let dao: Dao = ts::take_shared(ts);

        assert!(getDaoTotalShares(&dao) == amountToCheck, 2);

        // return dao
        ts::return_shared(dao);
    }

    #[test_only]
    public fun test_check_user_shares(ts: &mut ts::Scenario, sender: address, amountToCheck: u64){
        ts::next_tx(ts, sender);

        // get account 
        let accountCap: AccountCap = ts::take_from_sender<AccountCap>(ts);

        // check user shares
        assert!(getAccountShares(&accountCap) == amountToCheck, 1);

        ts::return_to_sender(ts, accountCap);
    }

    #[test]
    fun test_01_users_can_join_dao(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // user1 joins dao
        {
           test_join_dao(&mut ts, USER1, 50);
        };

        // user2 joins dao
        {
            test_join_dao(&mut ts, USER2, 100);
        };

        // check that user shares are incremented
        {
            test_check_user_shares(&mut ts, USER1, 50);
            test_check_user_shares(&mut ts, USER2, 100) 
        };

        // check that dao total shares are increased
        {   
            test_check_dao_shares(&mut ts, 150)
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    fun test_02_users_can_increase_shares(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // users join dao
        {
            test_join_dao(&mut ts, USER1, 50);
            test_join_dao(&mut ts, USER2, 200);
        };

        // increase user2 shares
        {
            test_increase_shares(&mut ts, USER2, 80)
        };

        // check that user2 shares increased
        {
            test_check_user_shares(&mut ts, USER2, 280);
        };

        // check total dao shares
        {
            test_check_dao_shares(&mut ts, 330);
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    fun test_03_users_can_redeem_shares(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // join dao
        {
            test_join_dao(&mut ts, USER1, 500);
            test_join_dao(&mut ts, USER2, 700);
        };

        // redeem USER2 shares
        {
            test_redeem_shares(&mut ts, USER2, 300);
        };

        // check that USER2 shares decreased
        {
            test_check_user_shares(&mut ts, USER2, 400)
        };

        // check that DAO shares decreased
        {
            test_check_dao_shares(&mut ts, 900);
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    #[expected_failure]
    fun test_04_user_cannot_redeem_more_than_deposited_shares(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // join dao
        {
            test_join_dao(&mut ts, USER3, 500);
        };

        // redeem shares
        {
            test_redeem_shares(&mut ts, USER3, 600);
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    fun test_05_user_can_create_proposal(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // join dao
        {
            test_join_dao(&mut ts, USER1, 300);
        };

        // create proposal
        {
            test_create_proposal(&mut ts, USER1, 200, USER3, &clock, );
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    #[expected_failure]
    fun test_06_user_cannot_create_proposal_with_amount_greater_than_available_funds(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // join dao
        {
            test_join_dao(&mut ts, USER1, 300);
            test_join_dao(&mut ts, USER2, 400);
        };

        // create proposal
        {
            // get dao
            let dao: Dao = ts::take_shared(&ts);
            let availableFunds = getDaoAvailableFunds(&dao);
            assert!(availableFunds == 700, 1);
            let moreThanAvailableFunds = availableFunds + 20;
            test_create_proposal(&mut ts, USER1, moreThanAvailableFunds, USER3, &clock, );
            ts::return_shared(dao);       
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }
    
    #[test]
    fun test_07_user_can_vote_proposal(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // join dao
        {
            test_join_dao(&mut ts, USER1, 300);
            test_join_dao(&mut ts, USER2, 400);
        };

        // create proposal
        {
            test_create_proposal(&mut ts, USER1, 400, USER3, &clock, );
        };

        // vote proposal
        {
            test_vote_proposal(&mut ts, USER1, &clock ); 
        };

        // check votes (proposal has only votes equivalent to user shares)
        {
            test_check_proposal_votes(&mut ts, 300);
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    #[expected_failure]
    fun test_08_user_can_only_vote_proposal_once(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // join dao
        {
            test_join_dao(&mut ts, USER1, 300);
            test_join_dao(&mut ts, USER2, 400);
        };

        // create proposal
        {
            test_create_proposal(&mut ts, USER1, 400, USER3, &clock, );
        };

        // vote proposal
        {
            test_vote_proposal(&mut ts, USER1, &clock ); 
        };

        // vote proposal again
        {
            test_vote_proposal(&mut ts, USER1, &clock ); 
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    #[expected_failure]
    fun test_09_user_can_not_vote_after_proposal_time_end(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // join dao
        {
            test_join_dao(&mut ts, USER1, 300);
            test_join_dao(&mut ts, USER2, 400);
        };

        // create proposal
        {
            test_create_proposal(&mut ts, USER1, 400, USER3, &clock, );
        };

        // vote proposal
        {
            test_vote_proposal(&mut ts, USER1, &clock ); 
        };

        // increment time to proposal end time 100 + 5
        {
            clock::increment_for_testing(&mut clock, 105);
        };

        // user 2 tries to vote after proposal times has ended
        {
            test_vote_proposal(&mut ts, USER2, &clock ); 
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    fun test_10_can_execute_successful_proposal(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // join dao
        {
            test_join_dao(&mut ts, USER1, 300);
            test_join_dao(&mut ts, USER2, 400);
        };

        // create proposal
        {
            test_create_proposal(&mut ts, USER1, 400, USER3, &clock, );
        };

        // vote proposal: proposal gets 100% votes
        {
            test_vote_proposal(&mut ts, USER1, &clock ); 
            test_vote_proposal(&mut ts, USER2, &clock );
        };

        // increment time to proposal end time 100 + 5
        {
            clock::increment_for_testing(&mut clock, 105);
        };

        // execute proposal
        {
            test_execute_proposal(&mut ts, USER2, &clock ); 
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    #[expected_failure]
    fun test_11_can_execute_failed_proposal(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // join dao
        {
            test_join_dao(&mut ts, USER1, 300);
            test_join_dao(&mut ts, USER2, 400);
            test_join_dao(&mut ts, USER3, 400);
        };

        // create proposal
        {
            test_create_proposal(&mut ts, USER1, 400, USER3, &clock, );
        };

        // vote proposal: proposal gets less than 70% votes
        {
            test_vote_proposal(&mut ts, USER1, &clock ); 
        };

        // increment time to proposal end time 100 + 5
        {
            clock::increment_for_testing(&mut clock, 105);
        };

        // execute proposal
        {
            test_execute_proposal(&mut ts, USER1, &clock ); 
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }

    #[test]
    #[expected_failure]
    fun test_12_cannot_execute_proposal_before_vote_time_end(){
        let ts = ts::begin(@0x0);
        let clock = clock::create_for_testing(ts::ctx(&mut ts));
    
        //  run the test init function
        {
            test_init(ts::ctx(&mut ts));
        };
        
        // join dao
        {
            test_join_dao(&mut ts, USER1, 300);
            test_join_dao(&mut ts, USER2, 400);
        };

        // create proposal
        {
            test_create_proposal(&mut ts, USER1, 400, USER3, &clock, );
        };

        // vote proposal: proposal gets less than 70% votes
        {
            test_vote_proposal(&mut ts, USER1, &clock ); 
            test_vote_proposal(&mut ts, USER2, &clock ); 
        };

        // execute proposal
        {
            test_execute_proposal(&mut ts, USER1, &clock ); 
        };

        clock::destroy_for_testing(clock);
        ts::end(ts);
    }
}