// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev ERC-5219 key/value response header or query parameter.
struct KeyValue {
    string key;
    string value;
}

/// @dev ERC-5219 Contract Resource Requests.
interface IDecentralizedApp {
    function request(string[] memory resource, KeyValue[] memory params)
        external
        view
        returns (uint16 statusCode, string memory body, KeyValue[] memory headers);
}

/// @dev ERC-165 Standard Interface Detection.
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title OnchainDataResource
/// @notice One autonomous contract-resource actor: priced writes and standard read projection.
/// @dev Inline bodies are deliberately public. Large or controlled-delivery bodies remain at an
///      external endpoint; this contract retains their SHA-256 identity, locator, controller,
///      version, and publication receipt.
contract OnchainDataResource is IDecentralizedApp, IERC165 {
    error EmptyResourcePath();
    error EmptyMediaType();
    error EmptyExternalLocator();
    error MissingDigest();
    error IncorrectWritePayment(uint256 expected, uint256 observed);
    error ResourceControlledByAnotherActor(bytes32 resourceKey, address controller);
    error NotFeeRecipient(address caller);
    error FeeWithdrawalFailed();

    struct Resource {
        bytes32 sha256Digest;
        address controller;
        uint64 version;
        bool externalBody;
        string mediaType;
        string body;
        string locator;
    }

    uint256 public immutable writePrice;
    address payable public immutable feeRecipient;
    mapping(bytes32 resourceKey => Resource resource) private resources;

    event ResourcePublished(
        bytes32 indexed resourceKey,
        bytes32 indexed sha256Digest,
        address indexed controller,
        uint64 version,
        bool externalBody,
        string mediaType,
        string locator
    );

    event WriteFeesWithdrawn(address indexed recipient, uint256 amount);

    constructor(uint256 exactWritePrice, address payable recipient) {
        if (recipient == address(0)) revert NotFeeRecipient(address(0));
        writePrice = exactWritePrice;
        feeRecipient = recipient;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IDecentralizedApp).interfaceId;
    }

    function resourceKey(string[] memory resource) public pure returns (bytes32) {
        if (resource.length == 0) revert EmptyResourcePath();
        return keccak256(abi.encode(resource));
    }

    function describe(string[] memory resource) external view returns (Resource memory) {
        return resources[resourceKey(resource)];
    }

    function publishInline(
        string[] calldata resource,
        string calldata mediaType,
        string calldata body
    ) external payable returns (bytes32 key, bytes32 digest, uint64 version) {
        if (bytes(mediaType).length == 0) revert EmptyMediaType();
        digest = sha256(bytes(body));
        key = resourceKey(resource);
        version = _admitWrite(key);
        resources[key] = Resource({
            sha256Digest: digest,
            controller: msg.sender,
            version: version,
            externalBody: false,
            mediaType: mediaType,
            body: body,
            locator: ""
        });
        emit ResourcePublished(key, digest, msg.sender, version, false, mediaType, "");
    }

    function publishExternal(
        string[] calldata resource,
        string calldata mediaType,
        string calldata locator,
        bytes32 sha256Digest
    ) external payable returns (bytes32 key, uint64 version) {
        if (bytes(mediaType).length == 0) revert EmptyMediaType();
        if (bytes(locator).length == 0) revert EmptyExternalLocator();
        if (sha256Digest == bytes32(0)) revert MissingDigest();
        key = resourceKey(resource);
        version = _admitWrite(key);
        resources[key] = Resource({
            sha256Digest: sha256Digest,
            controller: msg.sender,
            version: version,
            externalBody: true,
            mediaType: mediaType,
            body: "",
            locator: locator
        });
        emit ResourcePublished(key, sha256Digest, msg.sender, version, true, mediaType, locator);
    }

    function request(string[] memory resource, KeyValue[] memory params)
        external
        view
        returns (uint16 statusCode, string memory body, KeyValue[] memory headers)
    {
        if (resource.length == 0 || params.length != 0) {
            return (400, "unsupported resource request", new KeyValue[](0));
        }
        Resource storage selected = resources[keccak256(abi.encode(resource))];
        if (selected.controller == address(0)) {
            return (404, "resource not found", new KeyValue[](0));
        }

        headers = new KeyValue[](selected.externalBody ? 3 : 2);
        headers[0] = KeyValue({
            key: "Content-Type",
            value: selected.externalBody
                ? string.concat(
                    "message/external-body; access-type=URL; URL=\"", selected.locator, "\""
                )
                : selected.mediaType
        });
        headers[1] = KeyValue({
            key: "ETag", value: string.concat("\"", _hex(selected.sha256Digest), "\"")
        });
        if (selected.externalBody) {
            headers[2] = KeyValue({ key: "Content-Location", value: selected.locator });
            return (200, selected.locator, headers);
        }
        return (200, selected.body, headers);
    }

    function withdrawWriteFees() external {
        if (msg.sender != feeRecipient) revert NotFeeRecipient(msg.sender);
        uint256 amount = address(this).balance;
        (bool sent,) = feeRecipient.call{ value: amount }("");
        if (!sent) revert FeeWithdrawalFailed();
        emit WriteFeesWithdrawn(feeRecipient, amount);
    }

    function _admitWrite(bytes32 key) private view returns (uint64 version) {
        if (msg.value != writePrice) revert IncorrectWritePayment(writePrice, msg.value);
        Resource storage current = resources[key];
        if (current.controller != address(0) && current.controller != msg.sender) {
            revert ResourceControlledByAnotherActor(key, current.controller);
        }
        return current.version + 1;
    }

    function _hex(bytes32 value) private pure returns (string memory) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory encoded = new bytes(64);
        for (uint256 i = 0; i < 32; ++i) {
            uint8 byteValue = uint8(value[i]);
            encoded[i * 2] = alphabet[byteValue >> 4];
            encoded[i * 2 + 1] = alphabet[byteValue & 0x0f];
        }
        return string(encoded);
    }
}
