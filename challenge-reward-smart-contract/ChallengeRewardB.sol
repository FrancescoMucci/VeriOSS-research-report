pragma solidity >= 0.5.0 < 0.6.0;
import "github.com/oraclize/ethereum-api/provableAPI.sol";

/// @author Francesco Mucci
/// @title Version B of contract responsible for the partial rewarding process of the VeriOSS platform
contract ChallengeReward is usingProvable {

    enum States { InTransition, NOT_RCV, QRY_SNT, RES_RCV}
    
    struct Query {
        bytes32 id;
        uint expire;
    }

	string private constant FAILED_CHALLENGE_FLAG = "NOT PASSED"; // facoltativo // facoltativo //usarne una più corta
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
    bytes public proof; 

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
        expire = creation_time + _daysUntilExpire;
        generateChallengeCID = _generateChallengeCID;
        decommitSolveCID = _decommitSolveCID;
        provable_setProof(proofType_TLSNotary | proofStorage_IPFS); // facoltativo
        provable_setCustomGasPrice(CUSTOM_GAS_PRICE); // 4 Gwei // facoltativo
    }
  
    function __callback (bytes32 _queryId, string memory _result, bytes memory _proof) public {
        require(state == States.QRY_SNT);
        require(msg.sender == provable_cbAddress() && pendingQueries[_queryId] == true && now < query.expire); 
        state = States.InTransition; 
        delete pendingQueries[_queryId]; // pendingQueries[_queryId] = false;
        proof = _proof;
        debugInfoCID = _result;
        challengePassed = strCompare(_result, FAILED_CHALLENGE_FLAG) != 0;
        state = States.RES_RCV;
        if (challengePassed)
    	    hunter.transfer(partialReward);
    }

    function faceChallenge (string memory _encryptedDebugInfoCID) public payable {
        require(state == States.NOT_RCV);
        require(
            msg.sender == hunter && 
            now < expire && 
            provable_getPrice("nested", CUSTOM_GAS_LIMIT) > address(this).balance
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
        state = States.QRY_SNT; 
    }
    
    function nullifyQuery () public {
        require(state == States.QRY_SNT);
        require(msg.sender == issuer && now >= query.expire);
        state = States.InTransition; 
        delete pendingQueries[query.id];
        state = States.NOT_RCV;
    }
    
    function giveAnotherChance () public {
        require(state == States.RES_RCV);
        require(msg.sender == issuer && !challengePassed);
        state = States.NOT_RCV;
    }
    
    function removeContract () public {
        require (state == States.NOT_RCV ||  state == States.RES_RCV );
        require (msg.sender == issuer && now >= expire);
        state = States.InTransition; 
        selfdestruct(msg.sender);
    }

}