// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title VestingPeriod
 * @dev The vesting vault contract after the token sale
 * Taken from https://github.com/dandelionlabs-io/linear-vesting-contracts/blob/master/contracts/Vesting.sol
 */
contract VestingBase is AccessControl {
    using SafeMath for uint256;

    /// @notice Grant definition
    struct Grant {
        uint256 amount; // Total amount to claim
        uint256 totalClaimed; // Already claimed
        uint256 perSecond; // Reward per second
    }

    struct Pool {
        string name; // Name of the pool
        uint256 startTime; // Starting time of the vesting period in unix timestamp format
        uint256 endTime; // Ending time of the vesting period in unix timestamp format
        uint256 vestingDuration; // In seconds
        uint256 amount; // Total size of pool
        uint256 totalClaimed; // Total amount claimed till moment
        uint256 grants; // Amount of investors
    }

    /// @dev Used to translate vesting periods specified in days to seconds
    uint256 internal constant SECONDS_PER_DAY = 86400;

    /// @notice ERC20 token
    IERC20 public token;

    /// @notice Mapping of recipient address > token grant
    mapping(address => Grant) public tokenGrants;

    /// @notice Current vesting period is the same for all grants.
    /// @dev Each pool has its own contract.
    Pool public pool;

    bytes32 public constant OPERATORS = keccak256("OPERATORS");
    bytes32 public constant OPERATORS_ADMIN = keccak256("OPERATORS_ADMIN");

    /// @notice Event emitted when a new grant is created
    event GrantAdded(address indexed recipient, uint256 indexed amount);

    /// @notice Event emitted when tokens are claimed by a recipient from a grant
    event GrantTokensClaimed(
        address indexed recipient,
        uint256 indexed amountClaimed
    );

    /**
     * @notice Construct a new Vesting contract
     * @param _token Address of ERC20 token
     * @param _startTime starting time of the vesting period in timestamp format
     * @param _vestingDuration duration time of the vesting period in timestamp format
     */
    constructor(
        string memory _name,
        address _token,
        uint256 _startTime,
        uint256 _vestingDuration,
        address _admin
    ) {
        require(
            _token != address(0),
            "VestingPeriod::constructor: _token must be valid token address"
        );
        require(
            _startTime > 0 && _vestingDuration > 0,
            "VestingPeriod::constructor: One of the time parameters is 0"
        );
        require(
            _startTime > block.timestamp,
            "VestingPeriod::constructor: Starting time shalll be in a future time"
        );
        require(
            _vestingDuration > 0,
            "VestingPeriod::constructor: Duration of the period must be > 0"
        );
        if (_vestingDuration < SECONDS_PER_DAY) {
            require(
                _vestingDuration <= SECONDS_PER_DAY.mul(10).mul(365),
                "VestingPeriod::constructor: Duration should be less than 10 years"
            );
        }

        token = IERC20(_token);

        pool.name = _name;
        pool.startTime = _startTime;
        pool.vestingDuration = _vestingDuration;
        pool.endTime = _startTime.add(_vestingDuration);

        _setRoleAdmin(OPERATORS, OPERATORS_ADMIN);
        _setRoleAdmin(OPERATORS_ADMIN, OPERATORS_ADMIN);
        _setupRole(OPERATORS_ADMIN, _admin);
        _setupRole(OPERATORS, _admin);
    }

    /**
     * @notice Add list of grants in batch.
     * @param _recipients list of addresses of the stakeholders
     * @param _amounts list of amounts to be assigned to the stakeholders
     */
    function addTokenGrants(
        address[] memory _recipients,
        uint256[] memory _amounts
    ) public virtual onlyRole(OPERATORS) {
        require(
            _recipients.length > 0,
            "VestingPeriod::addTokenGrants: no recipients"
        );
        require(
            _recipients.length <= 100,
            "VestingPeriod::addTokenGrants: too many grants, it will probably fail"
        );
        require(
            _recipients.length == _amounts.length,
            "VestingPeriod::addTokenGrants: invalid parameters length (they should be same)"
        );

        uint256 amountSum = 0;
        for (uint16 i = 0; i < _recipients.length; i++) {
            require(
                _recipients[i] != address(0),
                "VestingPeriod:addTokenGrants: there is an address with value 0"
            );
            require(
                tokenGrants[_recipients[i]].amount == 0,
                "VestingPeriod::addTokenGrants: a grant already exists for one of the accounts"
            );
            require(
                _amounts[i] > 0,
                "VestingPeriod::addTokenGrant: amount == 0"
            );
            amountSum = amountSum.add(_amounts[i]);
        }

        // Transfer the grant tokens under the control of the vesting contract
        require(
            token.transferFrom(msg.sender, address(this), amountSum),
            "VestingPeriod::addTokenGrants: transfer failed"
        );

        for (uint16 i = 0; i < _recipients.length; i++) {
            Grant memory grant = Grant({
                amount: _amounts[i],
                totalClaimed: 0,
                perSecond: _amounts[i].div(pool.vestingDuration)
            });
            tokenGrants[_recipients[i]] = grant;
            emit GrantAdded(_recipients[i], _amounts[i]);
        }

        pool.amount = pool.amount.add(amountSum);
    }

    /**
     * @notice Get token grant for recipient
     * @param _recipient The address that has a grant
     * @return the grant
     */
    function getTokenGrant(address _recipient)
        external
        view
        returns (Grant memory)
    {
        return tokenGrants[_recipient];
    }

    /**
     * @notice Calculate the vested and unclaimed tokens available for `recipient` to claim
     * @dev Due to rounding errors once grant duration is reached, returns the entire left grant amount
     * @param _recipient The address that has a grant
     * @return The amount recipient can claim
     */
    function calculateGrantClaim(address _recipient)
        public
        view
        returns (uint256)
    {
        // For grants created with a future start date, that hasn't been reached, return 0, 0
        if (block.timestamp < pool.startTime) {
            return 0;
        }

        uint256 cap = block.timestamp;
        if (cap > pool.endTime) {
            cap = pool.endTime;
        }
        uint256 elapsedTime = cap.sub(pool.startTime);

        // If over vesting duration, all tokens vested
        if (elapsedTime >= pool.vestingDuration) {
            uint256 remainingGrant = tokenGrants[_recipient].amount.sub(
                tokenGrants[_recipient].totalClaimed
            );
            return remainingGrant;
        } else {
            uint256 amountVested = tokenGrants[_recipient].perSecond.mul(
                elapsedTime
            );
            uint256 claimableAmount = amountVested.sub(
                tokenGrants[_recipient].totalClaimed
            );
            return claimableAmount;
        }
    }

    /**
     * @notice Calculate the vested (claimed + unclaimed) tokens for `recipient`
     * @param _recipient The address that has a grant
     * @return Total vested balance (claimed + unclaimed)
     */
    function vestedBalance(address _recipient) external view returns (uint256) {
        // For grants created with a future start date, that hasn't been reached, return 0, 0
        if (block.timestamp < pool.startTime) {
            return 0;
        }

        uint256 cap = block.timestamp;
        if (cap > pool.endTime) {
            cap = pool.endTime;
        }

        // If over vesting duration, all tokens vested
        if (cap == pool.endTime) {
            return tokenGrants[_recipient].amount;
        } else {
            uint256 elapsedTime = cap.sub(pool.startTime);
            uint256 amountVested = tokenGrants[_recipient].perSecond.mul(
                elapsedTime
            );
            return amountVested;
        }
    }

    /**
     * @notice The balance claimed by `recipient`
     * @param _recipient The address that has a grant
     * @return the number of claimed tokens by `recipient`
     */
    function claimedBalance(address _recipient)
        external
        view
        returns (uint256)
    {
        return tokenGrants[_recipient].totalClaimed;
    }

    /**
     * @notice Allows a grant recipient to claim their vested tokens
     * @dev Errors if no tokens have vested
     * @dev It is advised recipients check they are entitled to claim via `calculateGrantClaim` before calling this
     */
    function claimVestedTokens() external {
        uint256 amountVested = calculateGrantClaim(msg.sender);
        require(
            amountVested > 0,
            "VestingPeriod::claimVestedTokens: amountVested is 0"
        );
        require(
            token.transfer(msg.sender, amountVested),
            "VestingPeriod::claimVestedTokens: transfer failed"
        );

        Grant storage tokenGrant = tokenGrants[msg.sender];

        tokenGrant.totalClaimed = uint256(
            tokenGrant.totalClaimed.add(amountVested)
        );
        pool.totalClaimed = pool.totalClaimed.add(amountVested);

        emit GrantTokensClaimed(msg.sender, amountVested);
    }

    /**
     * @notice Calculate the number of tokens that will vest per day for the given recipient
     * @param _recipient The address that has a grant
     * @return Number of tokens that will vest per day
     */
    function tokensVestedPerDay(address _recipient)
        external
        view
        returns (uint256)
    {
        return
            tokenGrants[_recipient].amount.div(
                pool.vestingDuration.div(SECONDS_PER_DAY)
            );
    }

    /**
     * @notice Calculate the number of tokens that will vest per day in the given period for an amount
     * @param _amount the amount to be checked
     * @return Number of tokens that will vest per day
     */
    function tokensVestedPerDay(uint256 _amount)
        external
        view
        returns (uint256)
    {
        return _amount.div(pool.vestingDuration.div(SECONDS_PER_DAY));
    }

    function changeAdmin(address _newAdmin) external onlyRole(OPERATORS_ADMIN) {
        grantRole(OPERATORS_ADMIN, _newAdmin);
        revokeRole(OPERATORS_ADMIN, msg.sender);
    }
}
