pragma solidity >= 0.5.0 < 0.6.0;
import "github.com/oraclize/ethereum-api/provableAPI.sol";

/// @author Francesco Mucci
/// @title Version A of contract responsible for the partial rewarding process of the VeriOSS platform
contract ChallengeReward is usingProvable {
    
    enum States {InTransition, NOT_PAS, QRY_SNT, PAS, DEL}
    struct Query {bytes32 id; uint expire;}
    
	string private constant FAILED_CHALLENGE_FLAG = "NOT PASSED"; // facoltativo //usarne una più corta
    uint private constant CUSTOM_GAS_LIMIT = 50000; // facoltativo
    uint private constant CUSTOM_GAS_PRICE = 4000000000; // 4 Gwei //facoltativo
    uint private constant PROVABLE_MAX_DELAY = 15 minutes;
    uint private creation_time = now;
    States private state = States.NOT_PAS;
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
    bytes public proof; 
    
    event LogNewProvableQuery(bytes32 indexed _queryId, string _notification); 
    event LogNullifiedProvableQuery(bytes32 indexed _queryId, string _notification);
    event LogChallengeOutcome(bool outcome);
    event LogContractRemoval(string description);
    
    modifier onlyAt(States _state) {
        require (state == _state, "Sorry, this function cannot be called in this state.");
        _;
    }
    
    modifier onlyBy(address _addr) {
        require (msg.sender == _addr, "Sorry, sender not authorized.");
        _;
    }
    
    modifier onlyBefore(uint _time) {
        require (now < _time, "Sorry, this function is called too late.");
        _;
    }
    
    modifier onlyAfter(uint _time) {
        require (now >= _time, "Sorry, this function is called too early.");
        _;
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
        payable 
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
  
    function __callback (bytes32 _queryId, string memory _result,  bytes memory _proof) 
        public 
        onlyAt(States.QRY_SNT)
        onlyBy(provable_cbAddress())
        onlyBefore(query.expire)
    {
        require(pendingQueries[_queryId] == true, "Sorry, this query is not pending."); 
        state = States.InTransition; 
        pendingQueries[_queryId] = false; // delete pendingQueries[_queryId];
        proof = _proof;
        debugInfoCID = _result;
        challengePassed = strCompare(_result, FAILED_CHALLENGE_FLAG) != 0;
        emit LogChallengeOutcome(challengePassed);
        if (challengePassed) {
            state = States.PAS;
    	    hunter.transfer(partialReward); // non è necessario usare il pattern withdrwal
        } else {
            state = States.NOT_PAS;
        }
    }

    function faceChallenge (string memory _encryptedDebugInfoCID) 
        public 
        payable // otherwise the function wil reject all Ether sent to it
        onlyAt(States.NOT_PAS)
        onlyBy(hunter)
        onlyBefore(expire)
    {
        require(
            provable_getPrice("nested", CUSTOM_GAS_LIMIT) > address(this).balance,  
            "Sorry, add some ETH to cover the fees."
        ); 
        state = States.InTransition; 
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
        state = States.QRY_SNT; 
    }
    
    function nullifyQuery () public onlyAt(States.QRY_SNT) onlyBy(issuer) onlyAfter(query.expire) { // fail-safe
        state = States.InTransition;
        pendingQueries[query.id] = false; // delete pendingQueries[_queryId];
        emit LogNullifiedProvableQuery(query.id, "Query expired, hunter should re-invoke faceChallenge.");
        state = States.NOT_PAS;
    }
    
    function removeContract () public onlyBy(issuer) onlyAfter(expire) { // fail-safe
        require (
            state == States.NOT_PAS ||  state == States.PAS, 
            "Sorry, this function cannot be called in this state.");
        state = States.DEL; 
        emit LogContractRemoval("The issuer is removing the contract.");
        selfdestruct(msg.sender);
    }

}