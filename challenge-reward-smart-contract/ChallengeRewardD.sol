pragma solidity >= 0.5.0 < 0.6.0;
import "github.com/oraclize/ethereum-api/provableAPI.sol";

/// @author Francesco Mucci
/// @title Version D of contract responsible for the partial rewarding process of the VeriOSS platform
contract ChallengeReward is usingProvable {
    
    enum States {InTransition, NOT_RCV, QRY_SNT, QRY_EXP, RES_RCV, EXP}
    struct Query {bytes32 id; uint expire;}
    
	string private constant FAILED_CHALLENGE_FLAG = "NOT PASSED"; // facoltativo //usarne una più corta
    uint private constant CUSTOM_GAS_LIMIT = 50000; // facoltativo
    uint private constant CUSTOM_GAS_PRICE = 4000000000; // 4 Gwei //facoltativo
    uint private constant PROVABLE_MAX_DELAY = 15 minutes;
    uint private creation_time = now;
    States private state = States.NOT_RCV;
    Query private query;
    mapping(bytes32 => bool) private pendingQueries;
    address public issuer;
    address public bounty;
    address payable public hunter;
    uint public partialReward;
    uint public expire;
    string public debugInfoCID;
    string public generateChallengeCID;
    string public decommitSolveCID;
    bool public challengePassed;
    bytes public proof; // facoltativo
    
    event LogTimedTransition(uint _now, uint _deadline, string _msg);
    event LogNewProvableQuery(bytes32 _queryId, string _notification); 
    event LogNullifiedProvableQuery(bytes32 _queryId, string _notification);
    event LogChallengeOutcome(bool _outcome);
    event LogRewardSent(address indexed _hunter, uint _partialReward, string _description);
    event LogAnotherChangeGiven(string _description);
    event LogContractRemoval(string _description);
    
    function timedTransitionTo (States _nextState, uint _deadline,  string memory _msg) private {
        if (now >= _deadline) {
            state = States.InTransition;
            emit LogTimedTransition(now, _deadline, _msg);
            state = _nextState;
        }
    }

    modifier timedTransitions() {
        if (state == States.QRY_SNT) {
            timedTransitionTo(States.QRY_EXP, query.expire, "Query expired.");
        } else {
            timedTransitionTo(States.EXP, query.expire, "Challenge expired.");
        }
        _;
    }

    modifier onlyAt(States _state) {
        require (state == _state, "Sorry, this function cannot be called in this state.");
        _;
    }
    
    modifier onlyBy(address _addr) {
        require (msg.sender == _addr, "Sorry, sender not authorized.");
        _;
    }
    
    modifier onlyIf(bool condition, string memory _failInfo) {
        require (condition, _failInfo);
        _;
    }
    
    modifier transitionTo(States _nextState) {
        state = States.InTransition;
        _;
        state = _nextState;
    }
    
    constructor (
        address _bounty, 
        address payable _hunter, 
        uint _partialReward, 
        uint _daysUntilExpire, 
        string memory _generateChallengeCID, 
        string memory _decommitSolveCID
    ) 
        public 
        payable // otherwise the function wil reject all Ether sent to it
    {
        issuer = msg.sender;
        bounty = _bounty;
        hunter = _hunter;
        partialReward = _partialReward;
        expire = creation_time + _daysUntilExpire; //attenzione a possibile overflow
        generateChallengeCID = _generateChallengeCID;
        decommitSolveCID = _decommitSolveCID;
        provable_setProof(proofType_TLSNotary | proofStorage_IPFS); // facoltativo
        provable_setCustomGasPrice(CUSTOM_GAS_PRICE); // 4 Gwei // facoltativo
    }
  
    function __callback (bytes32 _queryId, string memory _result, bytes memory _proof) 
        public 
        timedTransitions()
        onlyAt(States.QRY_SNT)
        onlyBy(provable_cbAddress())
        onlyIf(pendingQueries[_queryId], "Sorry, this query is not pending.")
        transitionTo(States.RES_RCV)
    {
        pendingQueries[_queryId] = false; // delete pendingQueries[_queryId];
        proof = _proof;
        debugInfoCID = _result;
        challengePassed = strCompare(_result, FAILED_CHALLENGE_FLAG) != 0;
        emit LogChallengeOutcome(challengePassed);
    }

    function faceChallenge (string memory _encryptedDebugInfoCID) 
        public 
        payable // otherwise the function wil reject all Ether sent to it
        timedTransitions()
        onlyAt(States.NOT_RCV)
        onlyBy(hunter)
        onlyIf(provable_getPrice("nested", CUSTOM_GAS_LIMIT) > address(this).balance, "Sorry, add some ETH to cover the fees.")
        transitionTo(States.QRY_SNT)
    {
        query.id = provable_query(
      	    "nested", 
      	    strConcat( //strConcat è ereditata da usingProvable
        	    "[computation] ['", 
                decommitSolveCID,
                "', '${[decrypt], ${[IPFS], ",
                _encryptedDebugInfoCID, "}}']"
            ), 
            CUSTOM_GAS_LIMIT // facoltativo
        );
        query.expire = now + PROVABLE_MAX_DELAY;
        pendingQueries[query.id] = true;
        emit LogNewProvableQuery(query.id, "Query sent, standing for the answer");
    }
    
    function nullifyQuery () 
        public
        timedTransitions()
        onlyAt(States.QRY_EXP)
        onlyBy(issuer)
        transitionTo(States.NOT_RCV)
    { // fail-safe
        pendingQueries[query.id] = false; // delete pendingQueries[query.id]; // attenzione ad usare delate con i mapping
        emit LogNullifiedProvableQuery(query.id, "Query expired, the hunter should re-invoke faceChallenge.");
    }
    
    function getRewarded () 
        public 
        timedTransitions()
        onlyAt(States.RES_RCV) 
        onlyBy(hunter) 
        onlyIf(challengePassed, "Sorry, the challenge is not passed.")
        transitionTo(state = States.RES_RCV)
    { // withdrawal pattern
        // zero the partialReward before sending to prevent re-entrancy attacks
        uint amount = partialReward; // facoltativo
        partialReward = 0; // facoltativo
        hunter.transfer(amount);
        emit LogRewardSent(hunter, partialReward, "Partial reward sent to the hunter.");
    }
    
    function giveAnotherChance () 
        public 
        timedTransitions()
        onlyAt(States.RES_RCV) 
        onlyBy(issuer)
        onlyIf(!challengePassed, "Sorry, the challenge is passed.")
        transitionTo(States.NOT_RCV)
    {
        emit LogAnotherChangeGiven("The hunter should re-invoke faceChallenge.");
    }
    
    function removeContract () 
        public 
        timedTransitions()
        onlyAt(States.EXP)
        onlyBy(issuer) 
    { // fail-safe
        emit LogContractRemoval("The issuer is removing the contract.");
        selfdestruct(msg.sender);
    }

}