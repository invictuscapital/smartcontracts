pragma solidity ^0.5.6;

import "./openzeppelin-solidity/contracts/token/ERC20/ERC20Detailed.sol";
import "./openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "./openzeppelin-solidity/contracts/token/ERC20/ERC20Burnable.sol";
import "./openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "./openzeppelin-solidity/contracts/access/roles/MinterRole.sol";
import "./openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "./openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "./openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./InvictusWhitelist.sol";


/**
 * Contract for CRYPTO10 Hedged (C10) fund.
 *
 */
contract C10Token is ERC20, ERC20Detailed, ERC20Burnable, Ownable, Pausable, MinterRole {

    using SafeERC20 for ERC20;
    using SafeMath for uint256;

    // Maps participant addresses to the eth balance pending token issuance
    mapping(address => uint256) public pendingBuys;
    // The participant accounts waiting for token issuance
    address[] public participantAddresses;

    // Maps participant addresses to the withdrawal request
    mapping (address => uint256) public pendingWithdrawals;
    address payable[] public withdrawals;

    uint256 private minimumWei = 50 finney;
    uint256 private fees = 5;  // 0.5% , or 5/1000
    uint256 private minTokenRedemption = 1 ether;
    uint256 private maxAllocationsPerTx = 50;
    uint256 private maxWithdrawalsPerTx = 50;
    Price public price;

    address public whitelistContract;

    struct Price {
        uint256 numerator;
        uint256 denominator;
    }

    event PriceUpdate(uint256 numerator, uint256 denominator);
    event AddLiquidity(uint256 value);
    event RemoveLiquidity(uint256 value);
    event DepositReceived(address indexed participant, uint256 value);
    event TokensIssued(address indexed participant, uint256 amountTokens, uint256 etherAmount);
    event WithdrawRequest(address indexed participant, uint256 amountTokens);
    event Withdraw(address indexed participant, uint256 amountTokens, uint256 etherAmount);
    event TokensClaimed(address indexed token, uint256 balance);

    constructor (uint256 priceNumeratorInput, address whitelistContractInput)
        ERC20Detailed("Crypto10 Hedged", "C10", 18)
        ERC20Burnable()
        Pausable() public {
            price = Price(priceNumeratorInput, 1000);
            require(priceNumeratorInput > 0, "Invalid price numerator");
            require(whitelistContractInput != address(0), "Invalid whitelist address");
            whitelistContract = whitelistContractInput;
    }

    /**
     * @dev fallback function that buys tokens if the sender is whitelisted.
     */
    function () external payable {
        buyTokens(msg.sender);
    }

    /**
     * @dev Explicitly buy via contract.
     */
    function buy() external payable {
        buyTokens(msg.sender);
    }

    /**
     * Sets the maximum number of allocations in a single transaction.
     * @dev Allows us to configure batch sizes and avoid running out of gas.
     */
    function setMaxAllocationsPerTx(uint256 newMaxAllocationsPerTx) external onlyOwner {
        require(newMaxAllocationsPerTx > 0, "Must be greater than 0");
        maxAllocationsPerTx = newMaxAllocationsPerTx;
    }

    /**
     * Sets the maximum number of withdrawals in a single transaction.
     * @dev Allows us to configure batch sizes and avoid running out of gas.
     */
    function setMaxWithdrawalsPerTx(uint256 newMaxWithdrawalsPerTx) external onlyOwner {
        require(newMaxWithdrawalsPerTx > 0, "Must be greater than 0");
        maxWithdrawalsPerTx = newMaxWithdrawalsPerTx;
    }

    /// Sets the minimum wei when buying tokens.
    function setMinimumBuyValue(uint256 newMinimumWei) external onlyOwner {
        require(newMinimumWei > 0, "Minimum must be greater than 0");
        minimumWei = newMinimumWei;
    }

    /// Sets the minimum number of tokens to redeem.
    function setMinimumTokenRedemption(uint256 newMinTokenRedemption) external onlyOwner {
        require(newMinTokenRedemption > 0, "Minimum must be greater than 0");
        minTokenRedemption = newMinTokenRedemption;
    }

    /// Updates the price numerator.
    function updatePrice(uint256 newNumerator) external onlyMinter {
        require(newNumerator > 0, "Must be positive value");

        price.numerator = newNumerator;

        allocateTokens();
        processWithdrawals();
        emit PriceUpdate(price.numerator, price.denominator);
    }

    /// Updates the price denominator.
    function updatePriceDenominator(uint256 newDenominator) external onlyMinter {
        require(newDenominator > 0, "Must be positive value");

        price.denominator = newDenominator;
    }

    /**
     * Whitelisted token holders can request token redemption, and withdraw ETH.
     * @param amountTokensToWithdraw The number of tokens to withdraw.
     * @dev withdrawn tokens are burnt.
     */
    function requestWithdrawal(uint256 amountTokensToWithdraw) external whenNotPaused 
        onlyWhitelisted {

        address payable participant = msg.sender;
        require(balanceOf(participant) >= amountTokensToWithdraw, 
            "Cannot withdraw more than balance held");
        require(amountTokensToWithdraw >= minTokenRedemption, "Too few tokens");

        burn(amountTokensToWithdraw);

        uint256 pendingAmount = pendingWithdrawals[participant];
        if (pendingAmount == 0) {
            withdrawals.push(participant);
        }
        pendingWithdrawals[participant] = pendingAmount.add(amountTokensToWithdraw);
        emit WithdrawRequest(participant, amountTokensToWithdraw);
    }

    /// Allows owner to claim any ERC20 tokens.
    function claimTokens(ERC20 token) external payable onlyOwner {
        require(address(token) != address(0), "Invalid address");
        uint256 balance = token.balanceOf(address(this));
        token.transfer(owner(), token.balanceOf(address(this)));
        emit TokensClaimed(address(token), balance);
    }
    
    /**
     * @dev Allows the owner to burn a specific amount of tokens on a participant's behalf.
     * @param value The amount of tokens to be burned.
     */
    function burnForParticipant(address account, uint256 value) public onlyOwner {
        _burn(account, value);
    }

    /**
     * @dev Function to mint tokens when not paused.
     * @param to The address that will receive the minted tokens.
     * @param value The amount of tokens to mint.
     * @return A boolean that indicates if the operation was successful.
     */
    function mint(address to, uint256 value) public onlyMinter whenNotPaused returns (bool) {
        _mint(to, value);

        return true;
    }

    /// Adds liquidity to the contract, allowing anyone to deposit ETH
    function addLiquidity() public payable {
        require(msg.value > 0, "Must be positive value");
        emit AddLiquidity(msg.value);
    }

    /// Removes liquidity, allowing managing wallets to transfer eth to the fund wallet.
    function removeLiquidity(uint256 amount) public onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");

        msg.sender.transfer(amount);
        emit RemoveLiquidity(amount);
    }

    /// Allow the owner to remove a minter
    function removeMinter(address account) public onlyOwner {
        require(account != msg.sender, "Use renounceMinter");
        _removeMinter(account);
    }

    /// Allow the owner to remove a pauser
    function removePauser(address account) public onlyOwner {
        require(account != msg.sender, "Use renouncePauser");
        _removePauser(account);
    }

    /// returns the number of withdrawals pending.
    function numberWithdrawalsPending() public view returns (uint256) {
        return withdrawals.length;
    }

    /// returns the number of pending buys, waiting for token issuance.
    function numberBuysPending() public view returns (uint256) {
        return participantAddresses.length;
    }

    /**
     * First phase of the 2-part buy, the participant deposits eth and waits
     * for a price to be set so the tokens can be minted.
     * @param participant whitelisted buyer.
     */
    function buyTokens(address participant) internal whenNotPaused onlyWhitelisted {
        assert(participant != address(0));

        // Ensure minimum investment is met
        require(msg.value >= minimumWei, "Minimum wei not met");

        uint256 pendingAmount = pendingBuys[participant];
        if (pendingAmount == 0) {
            participantAddresses.push(participant);
        }

        // Increase the pending balance and wait for the price update
        pendingBuys[participant] = pendingAmount.add(msg.value);

        emit DepositReceived(participant, msg.value);
    }

    /// Internal function to allocate token.
    function allocateTokens() internal {
        uint256 numberOfAllocations = participantAddresses.length <= maxAllocationsPerTx ? 
            participantAddresses.length : maxAllocationsPerTx;
        
        address payable ownerAddress = address(uint160(owner()));
        for (uint256 i = numberOfAllocations; i > 0; i--) {
            address participant = participantAddresses[i - 1];
            uint256 deposit = pendingBuys[participant];
            uint256 feeAmount = deposit.mul(fees) / 1000;
            uint256 balance = deposit.sub(feeAmount);

            uint256 newTokens = balance.mul(price.numerator) / price.denominator;
            pendingBuys[participant] = 0;
            participantAddresses.pop();

            ownerAddress.transfer(feeAmount);

            mint(participant, newTokens);   
            emit TokensIssued(participant, newTokens, balance);
        }
    }

    /// Internal function to process withdrawals.
    function processWithdrawals() internal {
        uint256 numberOfWithdrawals = withdrawals.length <= maxWithdrawalsPerTx ? 
            withdrawals.length : maxWithdrawalsPerTx;

        address payable ownerAddress = address(uint160(owner()));
        for (uint256 i = numberOfWithdrawals; i > 0; i--) {
            address payable participant = withdrawals[i - 1];
            uint256 tokens = pendingWithdrawals[participant];

            assert(tokens > 0); // participant must have requested a withdrawal

            uint256 withdrawValue = tokens.mul(price.denominator) / price.numerator;

            pendingWithdrawals[participant] = 0;
            withdrawals.pop();

            if (address(this).balance >= withdrawValue) {
                uint256 feeAmount = withdrawValue.mul(fees) / 1000;
                uint256 balance = withdrawValue.sub(feeAmount);

                participant.transfer(balance);

                ownerAddress.transfer(feeAmount);

                emit Withdraw(participant, tokens, balance);
            }
            else {
                mint(participant, tokens);
                emit Withdraw(participant, tokens, 0); // indicate a failed withdrawal
            }
        }
    }

    modifier onlyWhitelisted() {
        require(InvictusWhitelist(whitelistContract).isWhitelisted(msg.sender), "Must be whitelisted");
        _;
    }
}
