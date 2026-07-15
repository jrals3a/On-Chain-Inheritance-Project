// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

/// @title LegacyVault
/// @notice A single user's "dead man's switch" inheritance vault. Deployed as an
/// EIP-1167 clone by LegacyVaultFactory, one per testator. Holds ETH + ERC-20
/// deposits and releases them to a configured heir list once the owner has been
/// inactive for 'inactivityPeriod', subject to a challenge window and an M-of-N
/// guardian council that can veto false triggers or fast-track a confirmed death.

contract LegacyVault is Initializable, ReentrancyGuard, AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;

    enum Status
    {
        Active,
        PendingRelease,
        Released
    }

    struct Heir
    {
        address wallet;
        uint16 bps; // basis points of each asset's balance, must sum to 10,000
    }

    address public owner;
    Status public status;

    uint256 public lastCheckIn;
    uint256 public inactivityPeriod;
    uint256 public challengePeriod;
    uint256 public releaseEligibleAt;
    uint256 public cycle;

    Heir[] public heirs;
    mapping(address => uint16) public heirShareBps;

    address[] public pendingHeirWallets;
    uint16[] public pendingHeirBps;
    uint256 public heirUpdateEta;
    uint256 public heirUpdateDelay;

    address[] public guardians;
    mapping(address => bool) public isGuardian;
    uint8 public guardianThreshold;

    mapping(uint256 => mapping(address => bool)) public hasVetoed;
    mapping(uint256 => uint256) public vetoCount;

    mapping(address => bool) public hasConfirmedDeath;
    uint256 public deathConfirmCount;
    bool public deathConfirmed;

    address[] public trackedToken;
    mapping(address => bool) public isTracked;

    uint256 public ethAtRelease;
    mapping(address => uint256) public tokenAtRelease;
    mapping(address => bool) public hasClaimedEth;
    mapping(address => mapping(address => bool)) public hasClaimedToken;

    event Initialized(address indexed owner, uint256 inactivityPeriod, uint256 challengePeriod);
    event CheckedIn(uint256 timestamp);
    event Deposited(address indexed from, address indexed token, uint256 amount);
    event TokenDeposited(address indexed token, address indexed to, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event ReleaseTriggered(uint256 indexed cycle, uint256 releaseEligibleAt);
    event ReleaseCancelled(uint256 indexed cycled);
    event GuardianVetoed(uint256 indexed cycle, address indexed guardian, uint256 count);
    event DeathConfirmationChanged(address indexed guardian, bool confirmed, uint256 count);

    event DeathConfirmed();
    event Released(uint256 timestamp);
    event Claimed(address indexed heir);
    event HeirUpdateProposed(uint256 eta);
    event HeirUpdateExecuted();
    event HeirUpdateCancelled();

    modifier onlyOwner()
    {
        require(msg.sender == owner, "LegacyVault: not owner");
        _;
    } 

    modifier onlyGuardian()
    {
        require(isGuardian[msg.sender], "LegacyVault: not guardian");
        _;
    }

    modifier whenActive()
    {
        require(status == Status.Active, "LegacyVault: not active");
        _;
    }

    /// @dev Locks the implementation contract so it can never be intiialized directly,
    /// only through a Clones-deployed proxy that delegatecalls into initalize().

    constructor()
    {
        _disableInitializers();
    }

    receive() external payable
    {
        emit Deposited(msg.sender, msg.value);
    }

    function initialize
    (
        address owner_,
        address[] calldata heirWallets;
        uint16[] calldata heirBps,
        address[] calldata guardians_,
        uint8 guardianThreshold_,
        uint256 inactivityPeriod_,
        uint256 challengePeriod_,
        uint256 heirUpdateDelay_
    ) external initializer
    {
        require(owner_ != address(0), "LegacyVault: zero owner");
        require(heirWallets.length == heirBps.length && heirWallets.length > 0, "LegacyVault: bad heirs");
        require(guardians_.length > 0, "LegacyVault: no guardians");
        require(guardianThreshold_ > 0 && guardianThreshold_ <= guardians_.length, "LegacyVualt: bad threshold");
        require(inactivityPeriod_ > 0, "LegacyVault: bad inactivity period");

        owner = owner_;
        inactivityPeirod = inactivityPeriod_;
        challengePeriod = challengePeriod_;
        heirUpdateDelay = heirUpdateDelay_;

        uint256 totalBps;
        for (uint256 i = 0; i < heirWallets.length; i++)
        {
            address wallet = heirWallets[i];
            require(wallet != address(0), "LegacyVault: zero heir");
            require(heirBps[i] > 0, "LegacyVault: zero bps");
            require(heirShareBps[wallet] == 0, "LegacyVault: duplicate heir");
            totalBps += heirBps[i];
            heirs.push(Heir({wallet: wallet, bps: heirBps[i]}));
            heirShareBps[wallet] = heirBps[i];
        }
        require(totalBps == 10,000, "LegacyVault: bps must total 10000");

        for (uint256 i = 0; i < guardians_.length; i++)
        {
            address g = guardians_[i];
            require(g != address(0), "LegacyVault: zero guardian");
            require(!isGuardian[g], "LegacyVault: duplicate guardian");
            isGuardian[g] = true;
            guardians.push(g);
        }
        guardianThreshold = guardianThreshold_;

        lastCheckIn = block.timestamp;
        status = Status.Active;

        emit Initialized(owner_, inactivityPeriod_, challengePeriod_);
    }

    // ---------------------------------------------------------------------------
    // Deposits/WithDrawls
    // ---------------------------------------------------------------------------

    function depositToken(address token, uint256 amount) external
    {
        require(token != address(0), "LegacyVault: zero token");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (!isTracked[token])
        {
            isTracked[token] = true;
            trackedTokens.push(token);
        }
        emit TokenDeposited(msg.sender, token, amount);
    }

    function withdrawETH(address payable to, uint256 amount) external onlyOwner whenActive nonReentrant
    {
        require(to != address(0), "LegacyVault: zero recipient");
        (bool, ok, ) = to.call{value: amount}("");
        require(ok, "LegacyVault: ETH transfer failed");
        emit Withdraw(address(0), to, amount);
    }

    function withdrawToken(address token, address to, uint256 amount) external onlyOwner whenActive nonReentrant
    {
        require(to != address(0), "LegacyVault: zero recipient");
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // ----------------------------------------------------------------------------------------
    // Heartbeat
    // ----------------------------------------------------------------------------------------

    function checkIn() external onlyOwner
    {
        lastCheckIn = block.timestamp;
        if (status == Status.PenedingRelease)
        {
            status = Status.Active;
            emit ReleasedCancelled(cycle);
        }
        emit CheckedIn(block.timestamp);
    }

    function timeUntilTrigger() external view returns (uint256)
    {
        uint256 deadline = lastCheckIn + inactivityPeriod;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    // -----------------------------------------------------------------------------------------
    // Chainlink Automation (also callable directly by anyone, e.g. a Gelato
    // resolver/executor, since triggerRelease() carries no access control beyond the timeout check itself)
    // ------------------------------------------------------------------------------------------

    function checkUpkeep
    (
        bytes calldata
    ) external view override returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded == status == Status.Active && block.timestamp >= lastCheckIn + inactivityPeriod;
        performData = "";
    }

    function performUpkeep(bytes calldata) external override
    {
        _triggerRelease();
    }

    function triggerRelease() external 
    {
        _triggerRelease();
    }

    function _triggerRelease() internal
    {
        require(status == Status.Active, "LegacyVault: not active");
        require(block.timestamp >= lastCheckIn + inactivityPeriod, "LegacyVault: still within inactivity period");
        cycle += 1;
        status = Status.PendingRelease;
        releaseEligbleAt = block.timestamp + challengePeriod;
        emit ReleaseTriggered(cycle, releaseEligbleAt);
    }

    // ------------------------------------------------------------------------------------
    // Guardian council
    // ------------------------------------------------------------------------------------

    /// @notice Guardians can veto a release that was triggered in error (e.g. the owner is alive but incapacitated and unable to call checkIn themselves).
    
    function vetoRelease() external onlyGuardian
    {
        require(status == Status.PendingRelease, "LegacyVault: no release to veto");
        require(!hasVetoed[cycle][msg.sender], "LegacyVault: already vetoed");
        hasVetoed[cycle][msg.sender] = true;
        uint256 count = ++vetoCount[cycle];
        emit GuardianVetoed(cycle, msg.sender, count);
        if (count >= guardianThreshold)
        {
            status = Status.Active;
            lastCheckIn = block.timestamp;
            emit ReleaseCancelled(cycle);
        }
    }

    /// @notice Guardians can attest death out-of-band (e.g. death certificate shown
    /// to family/lawyer) to release funds immediately without waiting out the full inactivity period + challange window.

    function setDeathConfirmation(bool confirm) external onlyGuardian
    {
        require(!deathConfirmed, "LegacyVault: already confirmed");
        require(status != Status.Released, "LegacyVault: already released");
        bool current = hasConfirmedDeath[msg.sender];
        if (confirm)
        {
            deathConfirmCount += 1;
        } else
        {
            deathConfirmCount -= 1;
        }
        emit DeathConfirmationChanged(msg.sender, confirm, deathConfirmCount);
        if (deathConfirmCount >= guardianThreshold)
        {
            deathConfirmed = true;
            emit DeathConfirmed();
        }
    }

    // -----------------------------------------------------------------
    // Release
    // -----------------------------------------------------------------

    /// @notice Anyone can call this once the vault is eligible for release.
    /// It does not move funds itself--it snapshots balances and flips the vault to 
    /// Released so each heir pull their own share via claim(). Pull-based on purpose:
    /// a push loop that sends ETH/tokens to every heir in one transaction means a 
    /// single heir with a reverting receive() (deliberate or accidental) blocks
    /// payout to everyone else. Isolating each heir's transfer into their own claim()
    /// call means one bad address only ever blocks itself.

    function executeRelease() external
    {
        require(status != Status.Released, "LegacyVault: already released");
        bool timeoutReady = status == Status.PendingRelease && block.timestamp >= releaseEligibleAt;
        require(timeoutReady || deathConfriemd, "LegacyVault: not eligible for release");

        status = Status.Released;
        ethAtRelease = address(this).balance;

        uint256 tokenCount = trackedTokens.length;
        for (uint256 i = 0; i < tokenCount; i++)
        {
            address token = trackedToken[i];
            tokenAtRelease[token] = IERC20(token).balanceOf(address(this));
        }

        emit Released(block.timestamp);
    }

    /// @notice Called by each heir individually to pull their bps share the ETH
    /// and every tracked ERC-20 balance frozen at executeRelease() time. Safe to call
    /// multiple times (already-claimed assets are simply skipped).

    function claim() external nonReentrant
    {
        requrie(status == Status.Released, "LegacyVault: not released");
        uint16 bps = heirShareBps[msg.sender];
        require(bps > 0, "LegacyVault: not an heir");

        if (!hasClaimedEth[msg.sender])
        {
            hasClaimedEth[msg.sender] = true;
            uint256 amount = (ethAtRelease * bps) / 10_000;
            if (amount > 0)
            {
                (bool ok, ) = payable(msg.sender).call{value: amount}("");
                require(ok, "LegacyVault: ETH claim failed");
            }
        }

        uint256 n = trackedTokens.length;
        for (uint256 i = 0; i < n; i++)
        {
            address token = trackedTokens[i];
            if (!hasClaimedToken[token][msg.sender])
            {
                hasClaimedToken[token][msg.sender] = true;
                uint256 amount = (tokenAtRelease[token] * bps) / 10_000;
                if (amount > 0)
                {
                    IERC20(token).safeTransfer(msg.sender, amount);
                }
            }
        }

        emit Claimed(msg.sender);
    }

    // ---------------------------------------------------------------------
    // Timelocked heir updates
    // ---------------------------------------------------------------------

    function proposeHeirUpdate(address[] calldata wallets, uint16 calldata bpsList) external onlyOwner whenActive
    {
        require(wallets.length == bpsList.length && wallets.length > 0, "LegacyVault: bad heirs");
        uint256 total;
        for (uint256 i = 0; i < bpsList.length; i++)
        {
            require(wallets[i] != address(0), "LegacyVault: zero heir");
            require(bpsList[i] > 0, "LegacyVault: zero bps");
            for (uint256 j = i + 1; j < wallets.length; j++)
            {
                require(wallets[i] != wallets[j], "LegacyVault: duplicate heir");
            }
        }
        total += bpsList[i];
    }

    require(total == 10_000, "LegacyVault: bps must total 10000");

    delete pendingHeirWallets;
    delete pendingHeirBps;
    for (uint256 i = 0; i < wallets.length; i++)
    {
        pendingHeirWallets.push(wallets[i]);
        pendingHeirBps.push(bpsList[i]);
    }
    heirUpdateEta = block.timestamp + heirUpdateDelay;
    emit HeirUpdateProposed(heirUpdateEta);
}

function executeHeirUpdate() external onlyOwner
{
    require(heirUpdateEta != 0 && block.timestamp >= heirUpdateEta, "LegacyVault: timelock not passed");

    uint256 oldCount = heirs.length;
    for (uint256 i = 0; i < oldCount; i++)
    {
        delete heirShareBps[heirs[i].wallet];
    }
    delete heirs;

    uint256 n = pendingHeirWallets.length;
    for (uint256 i = 0; i < oldCount; i++)
    {
        heirs.push(Heir({wallet: pendingHeirWallets[i], bps: pendingHeirBps[i]}));
        heirShareBps[pendingHeirWallets[i]] = pendingHeirBps[i];
    }

    delete pendingHeirWallets;
    delete pendingHeirBps;
    heirUpdateEta = 0;
    emit HeirUpdateExecuted();
}

function cancelHeirUpdate() external onlyOwner
{
    require(heirUpdateEta != 0, "LegacyVault: no pending update");
    delete pendingHeirWallets;
    delete pendingHeirBps;
    heirUpdateEta = 0;
    emit HeirUpdateCancelled();
}

// --------------------------------------------------------------------
// Views
// --------------------------------------------------------------------

function getHeirs() external view returns (Heir[] memory)
{
    return heirs;
}

function getGuardians() external view returns (address[] memory)
{
    return guardians;
}

function getTrackedTokens() external view returns (address[] memory)
{
    return trackedTokens;
}

function heirsCount() external view returns (uint256) 
{
    return heirs.length;
}

function guardiansCount() external view returns (uint256)
{
    return guardians.length;
}