//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IERC20.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/IWETH.sol";
import "./libraries/UniswapV2Library.sol";
import "./libraries/AddressArrayLibrary.sol";

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface ICan {
    function toggleRevert() external;

    function transferOwnership(address newOwner) external;

    function emergencyTakeout(
        IERC20 _token,
        address _to,
        uint256 _amount
    ) external;

    function changeCanFee(uint256 _fee) external;

    function updateCan() external;

    function mintFor(address _user, uint256 _providedAmount) external;

    function burnFor(
        address _user,
        uint256 _providedAmount,
        uint256 _rewardAmount
    ) external;

    function transfer(
        address _from,
        address _to,
        uint256 _providingAmount,
        uint256 _rewardAmount
    ) external;

    function emergencySendToFarming(uint256 _amount) external;

    function emergencyGetFromFarming(uint256 _amount) external;

    function canInfo()
        external
        returns (
            uint256 totalProvidedTokenAmount,
            uint256 totalFarmingTokenAmount,
            uint256 accRewardPerShare,
            uint256 totalRewardsClaimed,
            uint256 farmId,
            address farm,
            address router,
            address lpToken,
            address providingToken,
            address rewardToken,
            uint256 fee
        );
}

contract Bounding is IERC20 {
    bool public revertFlag;
    uint256 public contractRequiredGtonShare;
    uint256 public allowedRewardPerTry;

    address public owner;
    address public treasury;
    address[] public admins;
    mapping(address => UserUnlock[]) public userUnlock;

    IWETH public eth;
    IERC20 public gton;
    IStaking public staking;
    AggregatorV3Interface public gtonPrice;
    Discounts[] public discounts;
    AllowedTokens[] public allowedTokens;

    struct AllowedTokens {
        AggregatorV3Interface price;
        address token;
        ICan can;
        uint256 minimalAmount;
    }

    struct UserUnlock {
        uint256 rewardDebt;
        uint256 amount;
        uint256 startBlock;
        uint256 delta;
    }

    struct Discounts {
        uint256 delta;
        uint256 discountMul;
        uint256 discountDiv;
    }

    constructor(
        IWETH _eth,
        IERC20 _gton,
        IStaking _staking,
        AggregatorV3Interface _gtonPrice,
        address _treasury,
        address[] memory _admins,
        uint _allowedRewardPerTry,
        uint _contractRequiredGtonShare
    ) {
        owner = msg.sender;
        eth = _eth;
        gton = _gton;
        staking = _staking;
        gtonPrice = _gtonPrice;
        treasury = _treasury;
        admins = _admins;
        allowedRewardPerTry = _allowedRewardPerTry;
        contractRequiredGtonShare = _contractRequiredGtonShare;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }
    modifier notReverted() {
        require(!revertFlag, "reverted");
        _;
    }

    function toggleRevert() public onlyOwner {
        revertFlag = !revertFlag;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        owner = newOwner;
    }

    modifier onlyAdmin() {
        require(
            msg.sender == owner ||
                AddressArrayLib.indexOf(admins, msg.sender) != -1,
            "Bounding: permitted to admins only"
        );
        _;
    }

    function setAdmins(address[] memory _admins) public onlyOwner {
        for (uint256 i = 0; i < _admins.length; i++) {
            admins.push(_admins[i]);
        }
    }

    function removeAdmins(address[] memory _admins) public onlyOwner {
        for (uint256 i = 0; i < _admins.length; i++) {
            AddressArrayLib.removeItem(admins, _admins[i]);
        }
    }

    function addAllowedToken(
        AggregatorV3Interface price,
        ICan can,
        uint256 minimalAmount
    ) public onlyOwner {
        (, , , , , , , , address token, , ) = can.canInfo();
        allowedTokens.push(
            AllowedTokens({
                price: price,
                token: token,
                can: can,
                minimalAmount: minimalAmount
            })
        );
    }

    function emergencyTokenWithdraw(
        address token,
        uint256 amount,
        address to
    ) public onlyOwner {
        IERC20(token).transfer(to, amount);
    }

    function addDiscount(
        uint256 delta,
        uint256 discountMul,
        uint256 discountDiv
    ) public onlyOwner {
        discounts.push(
            Discounts({
                delta: delta,
                discountMul: discountMul,
                discountDiv: discountDiv
            })
        );
    }

    function rmDiscount(uint256 id) public onlyOwner {
        discounts[id] = discounts[discounts.length];
        discounts.pop();
    }

    function changeDiscount(
        uint256 id,
        uint256 delta,
        uint256 discountMul,
        uint256 discountDiv
    ) public onlyOwner {
        discounts[id] = Discounts({
            delta: delta,
            discountMul: discountMul,
            discountDiv: discountDiv
        });
    }

    function changeAllowedToken(
        uint256 id,
        AggregatorV3Interface price,
        ICan can,
        uint256 minimalAmount
    ) public onlyOwner {
        (, , , , , , , , address token, , ) = can.canInfo();
        allowedTokens[id] = AllowedTokens({
            price: price,
            token: token,
            can: can,
            minimalAmount: minimalAmount
        });
    }

    function rmAllowedToken(uint256 id) public onlyOwner {
        allowedTokens[id] = allowedTokens[allowedTokens.length];
        allowedTokens.pop();
    }

    function changeAllowedRewardPerTry(uint256 _allowedRewardPerTry)
        public
        onlyOwner
    {
        allowedRewardPerTry = _allowedRewardPerTry;
    }

    function getTokenAmountWithDiscount(
        uint256 discountMul,
        uint256 discountDiv,
        AggregatorV3Interface tokenPrice,
        uint256 tokenAmount
    ) public view returns (uint256) {
        uint8 gtonDecimals = gtonPrice.decimals();
        (, int256 gtonPriceUSD, , , ) = gtonPrice.latestRoundData();

        uint8 tokenDecimals = tokenPrice.decimals();
        (, int256 tokenPriceUSD, , , ) = tokenPrice.latestRoundData();

        return
            uint256(
                (int256(tokenAmount) *
                    tokenPriceUSD *
                    int256(uint256(gtonDecimals)) *
                    int256(discountMul)) /
                    gtonPriceUSD /
                    int256(uint256(tokenDecimals)) /
                    int256(discountDiv)
            );
    }

    function createBound(
        uint256 boundId,
        uint256 tokenId,
        address tokenAddress,
        uint256 tokenAmount,
        uint256 discountMul,
        uint256 discountDiv
    ) public notReverted {
        Discounts memory disc = discounts[boundId];
        AllowedTokens memory tok = allowedTokens[tokenId];
        require(tok.token == tokenAddress, "ops");
        require(
            disc.discountMul == discountMul && disc.discountDiv == discountDiv,
            "ops"
        );
        require(tokenAmount > tok.minimalAmount, "amount lower than minimal");
        require(
            IERC20(tok.token).transferFrom(
                msg.sender,
                address(this),
                tokenAmount
            ),
            "not enough allowance"
        );

        uint256 amount = getTokenAmountWithDiscount(
            disc.discountMul,
            disc.discountDiv,
            tok.price,
            tokenAmount
        );
        // require that you havent claimed more than x percent of total supply of gton on this contract
        require(
            amount * 10000 <=
                gton.balanceOf(address(this)) * allowedRewardPerTry,
            "too much gton"
        );
        gton.approve(address(staking), amount);
        staking.mint(amount, address(this));
        emit Transfer(address(0), msg.sender, amount);
        uint256 share = staking.balanceToShare(amount);

        UserUnlock[] storage user = userUnlock[msg.sender];
        user.push(
            UserUnlock({
                rewardDebt: 0,
                amount: share,
                startBlock: block.number,
                delta: disc.delta
            })
        );

        // send to candyshop for treasury
        require(
            IERC20(tok.token).approve(address(tok.can), tokenAmount),
            "cant approve"
        );
        tok.can.mintFor(treasury, tokenAmount);
        contractRequiredGtonShare += share;
    }

    function createBoundByAdmin(
        uint256 amount,
        uint256 delta,
        address _user
    )
        public
        // todo: add admins and modifier
        notReverted
    {
        gton.transferFrom(msg.sender, address(this), amount);
        gton.approve(address(staking), amount);
        staking.mint(amount, address(this));
        emit Transfer(address(0), msg.sender, amount);
        uint256 share = staking.balanceToShare(amount);

        UserUnlock[] storage user = userUnlock[_user];
        user.push(
            UserUnlock({
                rewardDebt: 0,
                amount: share,
                startBlock: block.number,
                delta: delta
            })
        );
        contractRequiredGtonShare += share;
    }

    function accamulateUserRewards(address _user)
        internal
        returns (uint256 accamulatedAmount)
    {
        UserUnlock[] storage user = userUnlock[_user];
        for (uint256 i = 0; i < user.length; ) {
            uint256 currentUnlock = (user[i].delta *
                (block.number - user[i].startBlock)) / user[i].amount;
            accamulatedAmount += currentUnlock - user[i].rewardDebt;
            if (block.number >= user[i].startBlock + user[i].delta) {
                userUnlock[msg.sender][i] = userUnlock[msg.sender][
                    userUnlock[msg.sender].length
                ];
                userUnlock[msg.sender].pop();
            } else {
                user[i].rewardDebt = currentUnlock;
                i++;
            }
        }
    }

    function showUserRewards(address _user)
        public
        view
        returns (uint256 accamulatedAmount)
    {
        UserUnlock[] memory user = userUnlock[_user];
        for (uint256 i = 0; i < user.length; ) {
            uint256 currentUnlock = (user[i].delta *
                (block.number - user[i].startBlock)) / user[i].amount;
            accamulatedAmount += currentUnlock - user[i].rewardDebt;
        }
    }

    function claimBoundTotal(address to) public notReverted {
        uint256 accamulatedAmount = accamulateUserRewards(msg.sender);
        staking.transferShare(to, accamulatedAmount);
        contractRequiredGtonShare -= accamulatedAmount;
    }

    //smart token proxy here
    function name() public view override returns (string memory) {
        return staking.name();
    }

    function symbol() public view override returns (string memory) {
        return staking.symbol();
    }

    function decimals() public view override returns (uint8) {
        return staking.decimals();
    }

    function totalSupply() public view override returns (uint256) {
        return staking.totalSupply();
    }

    function balanceOf(address _owner) public view override returns (uint256) {
        return
            staking.shareToBalance(showUserRewards(_owner)) +
            staking.balanceOf(_owner);
    }

    function allowance(address _owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        return staking.allowance(_owner, spender);
    }

    function approve(address spender, uint256 value)
        public
        override
        returns (bool)
    {
        emit Approval(msg.sender, spender, value);
        claimBoundTotal(msg.sender);
        (, bytes memory result) = address(staking).delegatecall(
            abi.encodeWithSignature("approve(address,uint)", spender, value)
        );
        return abi.decode(result, (bool));
    }

    function transfer(address to, uint256 value)
        public
        override
        returns (bool)
    {
        emit Transfer(msg.sender, to, value);
        claimBoundTotal(msg.sender);
        (, bytes memory result) = address(staking).delegatecall(
            abi.encodeWithSignature("transfer(address,uint)", to, value)
        );
        return abi.decode(result, (bool));
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        emit Transfer(from, to, value);
        claimBoundTotal(msg.sender);
        (, bytes memory result) = address(staking).delegatecall(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint)",
                from,
                to,
                value
            )
        );
        return abi.decode(result, (bool));
    }

    function mint(uint256 _amount, address _to) public {
        gton.transferFrom(msg.sender, address(this), _amount);
        gton.approve(address(staking), _amount);
        claimBoundTotal(msg.sender);
        staking.mint(_amount, _to);
        emit Transfer(address(0), _to, _amount);
    }

    function burn(address _to, uint256 _share) public {
        emit Transfer(msg.sender, address(0), staking.shareToBalance(_share));
        claimBoundTotal(msg.sender);
        (bool success, ) = address(staking).delegatecall(
            abi.encodeWithSignature("burn(address,uint256)", _to, _share)
        );
        require(success, "Bounding: failed to burn");
    }
}
