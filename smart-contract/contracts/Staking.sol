// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Staking is Ownable, ReentrancyGuard {
    struct Plan {
        uint256 amount;
        uint256 baseApr;
        uint256 duration;
    }

    struct Stake {
        uint256 planId;
        uint256 amount;
        uint256 startTime;
        uint256 lastClaimWeek;
        bool active;
    }

    Plan[] public plans;
    mapping(address => Stake[]) public stakes;
    mapping(address => address) public referrals;
    mapping(address => uint256) public referralCounts;
    mapping(address => bool) public blacklist;
    mapping(address => bool) public registered;
    mapping(uint256 => uint256) public winnerPool;
    address public marketingWallet = 0xe5243d16e48c8b2921Bd5A335f1eB9b5467c1a65;
    address public winnerWallet = 0xe9346D3A804266fC0cf701084E2DD915ab9f2dFF;
    uint256 public bnbPrice = 600 * 10**18; // USD/BNB, 18 decimals (e.g., $600)
    uint256 public constant REGISTRATION_FEE_USD = 25 * 10**18; // $25
    uint256 public constant REFERRER_SHARE_USD = 16 * 10**18; // $16
    uint256 public constant MARKETING_SHARE_USD = 8 * 10**18; // $8
    uint256 public constant WINNER_SHARE_USD = 1 * 10**18; // $1
    uint256 public constant WEEK = 7 days;
    uint256 public constant TOTAL_WEEKS = 12;
    uint256 public constant MAX_REFERRALS = 100;
    uint256 public constant BASE_APR = 20000;
    uint256 public constant REFERRAL_BOOST_APR = 35000;
    uint256 public constant MAX_APR = 100000;
    uint256 public constant SUNDAY_2PM_UTC = 1722787200;

    event Staked(address indexed user, uint256 planId, uint256 amount);
    event PayoutClaimed(address indexed user, uint256 amount);
    event ReferralAdded(address indexed referrer, address indexed referee);
    event PrincipalReturned(address indexed user, uint256 amount);
    event MarketingWalletChanged(address indexed oldWallet, address indexed newWallet);
    event Blacklisted(address indexed wallet, bool status);
    event FundsWithdrawn(address indexed marketingWallet, uint256 amount);
    event Registered(address indexed user, address indexed referrer, uint256 fee);
    event WinnerPaid(address indexed winner, uint256 amount);
    event BnbPriceUpdated(uint256 oldPrice, uint256 newPrice);

    constructor() Ownable() {
        plans.push(Plan(25 ether, BASE_APR, TOTAL_WEEKS * WEEK));
        plans.push(Plan(50 ether, BASE_APR, TOTAL_WEEKS * WEEK));
        plans.push(Plan(100 ether, BASE_APR, TOTAL_WEEKS * WEEK));
        plans.push(Plan(200 ether, BASE_APR, TOTAL_WEEKS * WEEK));
        plans.push(Plan(400 ether, BASE_APR, TOTAL_WEEKS * WEEK));
        plans.push(Plan(500 ether, BASE_APR, TOTAL_WEEKS * WEEK));
        plans.push(Plan(750 ether, BASE_APR, TOTAL_WEEKS * WEEK));
        plans.push(Plan(1000 ether, BASE_APR, TOTAL_WEEKS * WEEK));
    }

    function register(address referrer) external payable nonReentrant {
        require(!registered[msg.sender], "Already registered");
        require(!blacklist[msg.sender], "Wallet is blacklisted");
        require(referrer != address(0) && referrer != msg.sender && !blacklist[referrer], "Invalid referrer");
        uint256 feeInBnb = (REGISTRATION_FEE_USD * 10**18) / bnbPrice;
        require(msg.value == feeInBnb, "Incorrect registration fee");

        registered[msg.sender] = true;

        uint256 referrerAmount = (REFERRER_SHARE_USD * 10**18) / bnbPrice;
        uint256 marketingAmount = (MARKETING_SHARE_USD * 10**18) / bnbPrice;
        uint256 winnerAmount = (WINNER_SHARE_USD * 10**18) / bnbPrice;
        uint256 currentWeek = (block.timestamp / WEEK);

        (bool success, ) = referrer.call{value: referrerAmount}("");
        require(success, "Referrer transfer failed");

        (success, ) = marketingWallet.call{value: marketingAmount}("");
        require(success, "Marketing transfer failed");

        winnerPool[currentWeek] += winnerAmount;

        if (referralCounts[referrer] < MAX_REFERRALS) {
            referrals[msg.sender] = referrer;
            referralCounts[referrer]++;
            emit ReferralAdded(referrer, msg.sender);
        }

        emit Registered(msg.sender, referrer, msg.value);
    }

    function stake(uint256 planId) external payable nonReentrant {
        require(registered[msg.sender], "Must register first");
        require(!blacklist[msg.sender], "Wallet is blacklisted");
        require(planId < plans.length, "Invalid plan");
        require(msg.value == plans[planId].amount, "Incorrect amount");

        stakes[msg.sender].push(Stake(planId, msg.value, block.timestamp, 0, true));
        emit Staked(msg.sender, planId, msg.value);
    }

    function getUserApr(address user) public view returns (uint256) {
        if (blacklist[user]) return 0;
        uint256 refCount = referralCounts[user];
        if (refCount < 5) return BASE_APR;
        uint256 apr = REFERRAL_BOOST_APR + ((refCount - 5) / 5) * 6500;
        return apr > MAX_APR ? MAX_APR : apr;
    }

    function calculatePayout(address user, uint256 stakeIndex) public view returns (uint256) {
        if (blacklist[user] || stakeIndex >= stakes[user].length) return 0;
        Stake memory userStake = stakes[user][stakeIndex];
        if (!userStake.active) return 0;
        uint256 apr = getUserApr(user);
        uint256 weeklyReturn = apr / 12;
        return (userStake.amount * weeklyReturn) / 10000;
    }

    function getPendingPayout(address user) public view returns (uint256) {
        uint256 currentWeek = (block.timestamp / WEEK);
        uint256 totalPayout = 0;

        for (uint256 i = 0; i < stakes[user].length; i++) {
            Stake memory userStake = stakes[user][i];
            if (userStake.active && userStake.lastClaimWeek < currentWeek) {
                totalPayout += calculatePayout(user, i);
                if ((block.timestamp - userStake.startTime) / WEEK >= TOTAL_WEEKS) {
                    totalPayout += userStake.amount;
                }
            }
        }
        return totalPayout;
    }

    function claimPayout() external nonReentrant {
        require(!blacklist[msg.sender], "Wallet is blacklisted");
        uint256 currentWeek = (block.timestamp / WEEK);
        uint256 sunday2pmTimestamp = SUNDAY_2PM_UTC + (currentWeek * WEEK);
        require(block.timestamp >= sunday2pmTimestamp, "Claims open Sunday 2 PM UTC");

        uint256 totalPayout = 0;
        for (uint256 i = 0; i < stakes[msg.sender].length; i++) {
            Stake storage userStake = stakes[msg.sender][i];
            if (userStake.active && userStake.lastClaimWeek < currentWeek) {
                uint256 payout = calculatePayout(msg.sender, i);
                if (payout > 0) {
                    totalPayout += payout;
                    userStake.lastClaimWeek = currentWeek;
                }
                if ((block.timestamp - userStake.startTime) / WEEK >= TOTAL_WEEKS) {
                    totalPayout += userStake.amount;
                    userStake.active = false;
                    emit PrincipalReturned(msg.sender, userStake.amount);
                }
            }
        }
        require(totalPayout > 0, "No payouts available");
        require(address(this).balance >= totalPayout, "Insufficient contract balance");

        (bool success, ) = msg.sender.call{value: totalPayout}("");
        require(success, "Payout failed");
        emit PayoutClaimed(msg.sender, totalPayout);
    }

    function payWeeklyWinner(uint256 week) external onlyOwner {
        uint256 amount = winnerPool[week];
        require(amount > 0, "No winner funds");
        require(address(this).balance >= amount, "Insufficient balance");

        winnerPool[week] = 0;
        (bool success, ) = winnerWallet.call{value: amount}("");
        require(success, "Winner payment failed");
        emit WinnerPaid(winnerWallet, amount);
    }

    function withdrawToMarketingWallet(uint256 amount) external onlyOwner {
        require(amount > 0 && address(this).balance >= amount, "Invalid amount");
        (bool success, ) = marketingWallet.call{value: amount}("");
        require(success, "Withdrawal failed");
        emit FundsWithdrawn(marketingWallet, amount);
    }

    function setMarketingWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Invalid wallet");
        address oldWallet = marketingWallet;
        marketingWallet = newWallet;
        emit MarketingWalletChanged(oldWallet, newWallet);
    }

    function setBnbPrice(uint256 newPrice) external onlyOwner {
        require(newPrice > 0, "Invalid price");
        uint256 oldPrice = bnbPrice;
        bnbPrice = newPrice;
        emit BnbPriceUpdated(oldPrice, newPrice);
    }

    function setBlacklist(address wallet, bool status) external onlyOwner {
        blacklist[wallet] = status;
        emit Blacklisted(wallet, status);
    }

    function getTotalStaked(address user) external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < stakes[user].length; i++) {
            if (stakes[user][i].active) {
                total += stakes[user][i].amount;
            }
        }
        return total;
    }

    function getReferrer(address user) external view returns (address) {
        return referrals[user];
    }
}