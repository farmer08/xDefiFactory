pragma solidity 0.5.17;

import "./XIERC20.sol";
import "./XSafeERC20.sol";
import "./XSafeMath.sol";
import "./ReentrancyGuard.sol";


import "./XERC20.sol";
import "./ERC20Detailed.sol";


interface IXStream {
    
    function createStream(
        address token,
        address recipient,
        uint256 depositAmount,
        uint256 streamType,
        uint256 startBlock
    )
    external
        returns (uint256 streamId);

    function isStream(uint256 streamId) external view returns (bool);

    function getStream(uint256 streamId)
        external
        view
        returns (
            address sender,
            address recipient,
            uint256 depositAmount,
            uint256 startBlock,
            uint256 kBlock,
            uint256 remaining,
            uint256 withdrawable,
            uint256 unlockRatio,
            uint256 lastRewardBlock
        );

    function fundStream(uint256 streamId, uint256 amount)
        external
        returns (bool);

    function withdrawFromStream(uint256 streamId, uint256 amount)
        external
        returns (bool);

    function balanceOf(uint256 streamId)
        external
        view
        returns (uint256 withdrawable, uint256 remaining);

    function cancelStream(uint256 streamId) external returns (bool);
    function hasStream(address who)
        external
        view
        returns (bool hasVotingStream, bool hasNormalStream);
        
    function getStreamId(address who, uint256 streamType)
        external
        view
        returns (uint256);
    function fundsToStream(address token ,uint256 streamId, uint256 amount)
        external
        returns (bool );
    function addMinter(address _minter) external;
}
interface IXDEX {
    function mint(address account, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) ;
    function addMinter(address _minter) external;

}
contract XFarmMasterFactory{
    address[] public farmMasterys;
    mapping(address => address[]) userInfo;
    address public operatorAddress;
    constructor() public{
        operatorAddress = msg.sender;
    }
    modifier onlyDev {
        require(msg.sender == operatorAddress, ":: Not operator");
        _;
    }
    address xstream = 0x791fa9F3d914a3CD2f1b975c04e9d8A18d2beD17;

    function deploy( address xdex,uint256 _startBlock,address _core, uint256[] memory _bonusEndBlocks,uint256[] memory _tokensPerBlock) public {
        address farmMastery = address(new XFarmMastery(xdex,xstream,_startBlock,_core,_bonusEndBlocks,_tokensPerBlock));
        farmMasterys.push(farmMastery);
        address[] storage uInfos = userInfo[msg.sender];
        uInfos.push(farmMastery);
        userInfo[msg.sender] = uInfos;

    }
}

// FarmMaster is the master of xDefi Farms.
contract XFarmMastery is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant ONE = 10**18;
    uint256 constant onePercent = 10**16;
    uint256 constant StreamTypeVoting = 0;
    uint256 constant StreamTypeNormal = 1;

    //min and max lpToken count in one pool
    uint256 public constant LpTokenMinCount = 1;
    uint256 public constant LpTokenMaxCount = 8;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt.
    }

    struct LpTokenInfo {
        IERC20 lpToken; // Address of LP token contract.
        // lpTokenType, Type of LP token
        //      Type0: XPT;
        //      Type1: UNI-LP;
        //      Type2: BPT;
        //      Type3: XLP;
        //      Type4: yCrv;
        uint256 lpTokenType;
        uint256 lpFactor;
        uint256 lpAccPerShare; // Accumulated XDEX per share, times 1e12. See below.
        mapping(address => UserInfo) userInfo; // Info of each user that stakes LP tokens.
    }

    // Info of each pool.
    struct PoolInfo {
        LpTokenInfo lpTokenInfo;
        uint256 poolFactor; // How many allocation factor assigned to this pool. XDEX to distribute per block.
        uint256 lastRewardBlock; // Last block number that XDEX distribution occurs.
    }

    /*
     * In [0, 40000) blocks, 240 XDEX per block, 9600000 XDEX distributed;
     * In [40000, 120000) blocks, 120 XDEX per block, 9600000 XDEX distributed;
     * In [120000, 280000) blocks, 60 XDEX per block, 9600000 XDEX distributed;
     * In [280001, 600000) blocks, 30 XDEX per block, 9600000 XDEX distributed;
     * After 600000 blocks, 8 XDEX distributed per block.
     */
    uint256[] public bonusEndBlocks ;

    // 240, 120, 60, 30, 8 XDEX per block
    uint256[] public tokensPerBlock ;

    // First deposit incentive (once for each new user), 10 XDEX
    uint256 public constant bonusFirstDeposit = 10 * ONE;

    address public core;
    address public SAFU;
    // whitelist of claimable airdrop tokens
    mapping(address => bool) public claimableTokens;

    // The XDEX TOKEN
    // IXDEXToken public xdex;
    address public xdexToken;
    address public stream ;//= 0x791fa9F3d914a3CD2f1b975c04e9d8A18d2beD17;

    // The Halflife Protocol
    // IXStream public stream;

    // The main voting pool id
    uint256 public votingPoolId;

    // The block number when Token farming starts.
    uint256 public startBlock;

    // Info of each pool.
    PoolInfo[] poolInfo;

    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalXFactor = 0;

    event AddPool(
        uint256 indexed pid,
        address indexed lpToken,
        uint256 indexed lpType,
        uint256 lpFactor
    );

    event AddLP(
        uint256 indexed pid,
        address indexed lpToken,
        uint256 indexed lpType,
        uint256 lpFactor
    );

    event UpdateFactor(
        uint256 indexed pid,
        address indexed lpToken,
        uint256 lpFactor
    );

    event Deposit(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    event Withdraw(
        address indexed user,
        uint256 indexed pid,
        address indexed lpToken,
        uint256 amount
    );

    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        address indexed lpToken,
        uint256 amount
    );

    event SetSAFU(address indexed SAFU);
    event Claim(
        address indexed SAFU,
        address indexed token,
        uint256 indexed amount
    );

    event CoreTransferred(address indexed _core, address indexed _coreNew);

    /**
     * @dev Throws if the msg.sender unauthorized.
     */
    modifier onlyCore() {
        require(msg.sender == core, "Not authorized, only core");
        _;
    }

    /**
     * @dev Throws if the pid does not point to a valid pool.
     */
    modifier poolExists(uint256 _pid) {
        require(_pid < poolInfo.length, "pool does not exist");
        _;
    }
    
    constructor(
        address _xdex,
        address _stream,
        uint256 _startBlock,
        address _core,
        uint256[] memory _bonusEndBlocks,
        uint256[] memory _tokensPerBlock
    ) public {
        xdexToken = _xdex;
        // xdex = IXDEX(_xdex);
        stream = _stream;
        startBlock = _startBlock;
        core = _core;
        bonusEndBlocks = _bonusEndBlocks;
        tokensPerBlock = _tokensPerBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Set the voting pool id. Can only be called by the core.
    function setVotingPool(uint256 _pid) public onlyCore {
        votingPoolId = _pid;
    }

    // Add a new lp to the pool. Can only be called by the core.
    // DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function addPool(
        IERC20 _lpToken,
        uint256 _lpTokenType,
        uint256 _lpFactor,
        bool _withUpdate
    ) public onlyCore {
        require(_lpFactor > 0, "Lp Token Factor is zero");

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 _lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;

        totalXFactor = totalXFactor.add(_lpFactor);

        uint256 poolinfos_id = poolInfo.length++;
        poolInfo[poolinfos_id].poolFactor = _lpFactor;
        poolInfo[poolinfos_id].lastRewardBlock = _lastRewardBlock;
        poolInfo[poolinfos_id].lpTokenInfo= LpTokenInfo({
                lpToken: _lpToken,
                lpTokenType: _lpTokenType,
                lpFactor: _lpFactor,
                lpAccPerShare: 0
            });
        emit AddPool(poolinfos_id, address(_lpToken), _lpTokenType, _lpFactor);
    }

    function getLpTokenInfosByPoolId(uint256 _pid)
        public
        view
        poolExists(_pid)
        returns (address lpToken,uint256 lpTokenType,uint256 lpFactor,uint256 lpAccPerShare)
    {
        PoolInfo memory pool  = poolInfo[_pid];
        lpToken = address(pool.lpTokenInfo.lpToken);
        lpTokenType = pool.lpTokenInfo.lpTokenType;
        lpFactor = pool.lpTokenInfo.lpFactor;
        lpAccPerShare = pool.lpTokenInfo.lpAccPerShare;
    }

    // View function to see user lpToken amount in pool on frontend.
    function getUserLpAmounts(uint256 _pid, address _user)
        public
        view
        poolExists(_pid)
        returns (address lpToken, uint256  amount)
    {
        PoolInfo memory pool = poolInfo[_pid];
        lpToken = address(pool.lpTokenInfo.lpToken);
         UserInfo memory user = poolInfo[_pid].lpTokenInfo
                .userInfo[_user];
        amount = user.amount;
    }

    // Update the given lpToken's lpFactor in the given pool. Can only be called by the owner.
    // `_lpFactor` is 0, means the LpToken is soft deleted from pool.
    function setLpFactor(
        uint256 _pid,
        IERC20 _lpToken,
        uint256 _lpFactor,
        bool _withUpdate
    ) public onlyCore poolExists(_pid) {
        if (_withUpdate) {
            massUpdatePools();
        }

        PoolInfo storage pool = poolInfo[_pid];
        //update poolFactor and totalXFactor
        uint256 poolFactorNew = pool
            .poolFactor
            .sub(pool.lpTokenInfo.lpFactor)
            .add(_lpFactor);
        pool.lpTokenInfo.lpFactor = _lpFactor;

        totalXFactor = totalXFactor.sub(poolInfo[_pid].poolFactor).add(
            poolFactorNew
        );
        poolInfo[_pid].poolFactor = poolFactorNew;

        emit UpdateFactor(_pid, address(_lpToken), _lpFactor);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            if (poolInfo[pid].poolFactor > 0) {
                updatePool(pid);
            }
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public poolExists(_pid) {
        if (block.number <= poolInfo[_pid].lastRewardBlock) {
            return;
        }

        if (poolInfo[_pid].poolFactor == 0 || totalXFactor == 0) {
            return;
        }

        PoolInfo storage pool = poolInfo[_pid];
        (uint256 poolReward, , ) = getXCountToReward(
            pool.lastRewardBlock,
            block.number
        );
        poolReward = poolReward.mul(pool.poolFactor).div(totalXFactor);

        LpTokenInfo memory lpInfo = pool.lpTokenInfo;
        uint256 totalLpSupply = lpInfo.lpToken.balanceOf(address(this));
        if (totalLpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 lpReward = poolReward.mul(lpInfo.lpFactor).div(
                pool.poolFactor
            );
        lpInfo.lpAccPerShare = lpInfo.lpAccPerShare.add(
                lpReward.mul(1e12).div(totalLpSupply)
            );

       

        IXDEX(xdexToken).mint(address(this), poolReward);
        pool.lastRewardBlock = block.number;
    }

    // View function to see pending XDEX on frontend.
    function pendingXDEX(uint256 _pid, address _user)
        external
        view
        poolExists(_pid)
        returns (uint256)
    {
        PoolInfo memory pool = poolInfo[_pid];

        uint256 totalPending = 0;
        if (totalXFactor == 0 || pool.poolFactor == 0) {
            UserInfo memory user = poolInfo[_pid].lpTokenInfo
                    .userInfo[_user];
            totalPending = totalPending.add(
                    user
                        .amount
                        .mul(pool.lpTokenInfo.lpAccPerShare)
                        .div(1e12)
                        .sub(user.rewardDebt)
                );

            return totalPending;
        }

        (uint256 xdexReward, , ) = getXCountToReward(
            pool.lastRewardBlock,
            block.number
        );

        uint256 poolReward = xdexReward.mul(pool.poolFactor).div(totalXFactor);
        LpTokenInfo memory lpInfo = pool.lpTokenInfo;

        uint256 lpSupply = lpInfo.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock) {
            if (lpSupply == 0) {
                return 0;
            }
            uint256 lpReward = poolReward.mul(lpInfo.lpFactor).div(
                pool.poolFactor
            );
            lpInfo.lpAccPerShare = lpInfo.lpAccPerShare.add(
                lpReward.mul(1e12).div(lpSupply)
            );
        }
        UserInfo memory user = poolInfo[_pid].lpTokenInfo
            .userInfo[_user];
        totalPending = totalPending.add(
            user.amount.mul(lpInfo.lpAccPerShare).div(1e12).sub(
                user.rewardDebt
            )
        );

        return totalPending;
    }

    // Deposit LP tokens to FarmMaster for XDEX allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount
    ) public poolExists(_pid) {
        require(msg.sender == tx.origin, "do not deposit from contract");

        PoolInfo storage pool = poolInfo[_pid];
        updatePool(_pid);

        UserInfo storage user = poolInfo[_pid].lpTokenInfo.userInfo[msg
            .sender];

        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.lpTokenInfo.lpAccPerShare)
                .div(1e12)
                .sub(user.rewardDebt);

            if (pending > 0) {
                //create the stream or add funds to stream
                (bool hasVotingStream, bool hasNormalStream) = IXStream(stream).hasStream(
                    msg.sender
                );

                if (_pid == votingPoolId) {
                    if (hasVotingStream) {
                        //add funds
                        uint256 streamId = IXStream(stream).getStreamId(
                            msg.sender,
                            StreamTypeVoting
                        );
                        require(streamId > 0, "not valid stream id");

                        IXDEX(xdexToken).approve(stream, pending);
                        IXStream(stream).fundsToStream(xdexToken,streamId, pending);
                    }
                } else {
                    if (hasNormalStream) {
                        //add funds
                        uint256 streamId = IXStream(stream).getStreamId(
                            msg.sender,
                            StreamTypeNormal
                        );
                        require(streamId > 0, "not valid stream id");

                        IXDEX(xdexToken).approve(stream, pending);
                        IXStream(stream).fundsToStream(xdexToken,streamId, pending);
                    }
                }
            }
        } else {
            uint256 streamStart = block.number + 1;
            if (block.number < startBlock) {
                streamStart = startBlock;
            }

            //if it is the first deposit
            (bool hasVotingStream, bool hasNormalStream) = IXStream(stream).hasStream(
                msg.sender
            );

            //create the stream for First Deposit Bonus
            if (_pid == votingPoolId) {
                if (hasVotingStream == false) {
                    IXDEX(xdexToken).mint(address(this), bonusFirstDeposit);
                    IXDEX(xdexToken).approve(stream, bonusFirstDeposit);
                    IXStream(stream).createStream(
                        xdexToken,
                        msg.sender,
                        bonusFirstDeposit,
                        StreamTypeVoting,
                        streamStart
                    );
                }
            } else {
                if (hasNormalStream == false) {
                    IXDEX(xdexToken).mint(address(this), bonusFirstDeposit);
                    IXDEX(xdexToken).approve(stream, bonusFirstDeposit);
                    IXStream(stream).createStream(
                        xdexToken,
                        msg.sender,
                        bonusFirstDeposit,
                        StreamTypeNormal,
                        streamStart
                    );
                }
            }
        }

        if (_amount > 0) {
            pool.lpTokenInfo.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            user.amount = user.amount.add(_amount);
        }

        user.rewardDebt = user
            .amount
            .mul(pool.lpTokenInfo.lpAccPerShare)
            .div(1e12);

        emit Deposit(msg.sender, _pid,  _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(
        uint256 _pid,
        IERC20 _lpToken,
        uint256 _amount
    ) public nonReentrant poolExists(_pid) {
        require(msg.sender == tx.origin, "do not withdraw from contract");

        PoolInfo storage pool = poolInfo[_pid];
        updatePool(_pid);

        UserInfo storage user = poolInfo[_pid].lpTokenInfo.userInfo[msg
            .sender];
        require(user.amount >= _amount, "withdraw: _amount not good");

        uint256 pending = user
            .amount
            .mul(pool.lpTokenInfo.lpAccPerShare)
            .div(1e12)
            .sub(user.rewardDebt);

        if (pending > 0) {
            //create the stream or add funds to stream
            (bool hasVotingStream, bool hasNormalStream) = IXStream(stream).hasStream(
                msg.sender
            );

            /* Approve the Stream contract to spend. */
            IXDEX(xdexToken).approve(stream, pending);

            if (_pid == votingPoolId) {
                if (hasVotingStream) {
                    //add fund
                    uint256 streamId = IXStream(stream).getStreamId(
                        msg.sender,
                        StreamTypeVoting
                    );
                    require(streamId > 0, "not valid stream id");

                    IXDEX(xdexToken).approve(stream, pending);
                    IXStream(stream).fundsToStream(xdexToken,streamId, pending);
                }
            } else {
                if (hasNormalStream) {
                    //add fund
                    uint256 streamId = IXStream(stream).getStreamId(
                        msg.sender,
                        StreamTypeNormal
                    );
                    require(streamId > 0, "not valid stream id");

                    IXDEX(xdexToken).approve(stream, pending);
                    IXStream(stream).fundsToStream(xdexToken,streamId, pending);
                }
            }
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpTokenInfo.lpToken.safeTransfer(
                address(msg.sender),
                _amount
            );
        }
        user.rewardDebt = user
            .amount
            .mul(pool.lpTokenInfo.lpAccPerShare)
            .div(1e12);

        emit Withdraw(msg.sender, _pid, address(_lpToken), _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid)
        public
        nonReentrant
        poolExists(_pid)
    {
        PoolInfo storage pool = poolInfo[_pid];
        LpTokenInfo storage lpInfo = pool.lpTokenInfo;
        UserInfo storage user = lpInfo.userInfo[msg.sender];

        if (user.amount > 0) {
            lpInfo.lpToken.safeTransfer(address(msg.sender), user.amount);

            emit EmergencyWithdraw(
                msg.sender,
                _pid,
                address(lpInfo.lpToken),
                user.amount
            );
            user.amount = 0;
            user.rewardDebt = 0;
        }
    }

    function getXCountToReward(uint256 _from, uint256 _to)
        public
        view
        returns (
            uint256 _totalReward,
            uint256 _stageFrom,
            uint256 _stageTo
        )
    {
        require(_from <= _to, "_from must <= _to");

        uint256 stageFrom = 0;
        uint256 stageTo = 0;

        if (_to < startBlock) {
            return (0, stageFrom, stageTo);
        }
        if(bonusEndBlocks.length==0) return (0, stageFrom, stageTo);
        if (
            _from >= startBlock.add(bonusEndBlocks[bonusEndBlocks.length - 1])
        ) {
            return (
                _to.sub(_from).mul(tokensPerBlock[tokensPerBlock.length - 1]),
                stageFrom,
                stageTo
            );
        }

        uint256 total = 0;

        for (uint256 i = 0; i < bonusEndBlocks.length; i++) {
            uint256 actualEndBlock = startBlock.add(bonusEndBlocks[i]);
            if (_from > actualEndBlock) {
                stageFrom = stageFrom.add(1);
            }
            if (_to > actualEndBlock) {
                stageTo = stageTo.add(1);
            }
        }

        uint256 tStageFrom = stageFrom;
        while (_from < _to) {
            if (_from < startBlock) {
                _from = startBlock;
            }
            uint256 indexDiff = stageTo.sub(tStageFrom);
            if (indexDiff == 0) {
                total += (_to - _from) * tokensPerBlock[tStageFrom];
                _from = _to;
            } else if (indexDiff > 0) {
                uint256 actualRes = startBlock.add(bonusEndBlocks[tStageFrom]);
                total += (actualRes - _from) * tokensPerBlock[tStageFrom];
                _from = actualRes;
                tStageFrom = tStageFrom.add(1);
            } else {
                //this never happen
                break;
            }
        }

        return (total, stageFrom, stageTo);
    }

    function getCurRewardPerBlock() public view returns (uint256) {
        uint256 bnum = block.number;
        if (bnum < startBlock) {
            return 0;
        }
        if(bonusEndBlocks.length==0) return 0;
        if (bnum >= startBlock.add(bonusEndBlocks[bonusEndBlocks.length - 1])) {
            return tokensPerBlock[tokensPerBlock.length - 1];
        }
        uint256 stage = 0;
        for (uint256 i = 0; i < bonusEndBlocks.length; i++) {
            uint256 actualEndBlock = startBlock.add(bonusEndBlocks[i]);
            if (bnum > actualEndBlock) {
                stage = stage.add(1);
            }
        }

        require(
            stage >= 0 && stage < tokensPerBlock.length,
            "tokensPerBlock.length: not good"
        );
        return tokensPerBlock[stage];
    }

    // Any airdrop tokens (in whitelist) sent to this contract, should transfer to SAFU
    function claimRewards(address token, uint256 amount) public onlyCore {
        require(SAFU != address(0), "not valid SAFU address");
        require(claimableTokens[token], "not claimable token");

        IERC20(token).safeTransfer(SAFU, amount);
        emit Claim(SAFU, token, amount);
    }

    function updateClaimableTokens(address token, bool claimable)
        public
        onlyCore
    {
        claimableTokens[token] = claimable;
    }

    function setCore(address _core) public onlyCore {
        core = _core;
        emit CoreTransferred(core, _core);
    }

    function setSAFU(address _safu) public onlyCore {
        SAFU = _safu;
        emit SetSAFU(_safu);
    }
}
