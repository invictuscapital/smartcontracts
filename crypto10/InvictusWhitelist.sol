pragma solidity ^0.5.6;

import "./openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "./openzeppelin-solidity/contracts/access/roles/WhitelistedRole.sol";

/**
 * Manages whitelisted addresses.
 *
 */
contract InvictusWhitelist is Ownable, WhitelistedRole {
    constructor ()
        WhitelistedRole() public {
    }

    /// @dev override to support legacy name
    function verifyParticipant(address participant) public onlyWhitelistAdmin {
        if (!isWhitelisted(participant)) {
            addWhitelisted(participant);
        }
    }

    /// Allow the owner to remove a whitelistAdmin
    function removeWhitelistAdmin(address account) public onlyOwner {
        require(account != msg.sender, "Use renounceWhitelistAdmin");
        _removeWhitelistAdmin(account);
    }
}