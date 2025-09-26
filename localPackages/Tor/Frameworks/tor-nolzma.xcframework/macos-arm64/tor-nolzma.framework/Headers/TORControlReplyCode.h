//
//  TORControlReplyCode.h
//  Tor
//
//  Created by Denis Kutlubaev on 30.03.2021.
//

#ifndef TORControlReplyCode_h
#define TORControlReplyCode_h

/**
 TOR control reply codes
 https://github.com/torproject/torspec/blob/master/control-spec.txt

 The following codes are defined:

 250 OK
 251 Operation was unnecessary
 [Tor has declined to perform the operation, but no harm was done.]

 451 Resource exhausted

 500 Syntax error: protocol

 510 Unrecognized command
 511 Unimplemented command
 512 Syntax error in command argument
 513 Unrecognized command argument
 514 Authentication required
 515 Bad authentication

 550 Unspecified Tor error

 551 Internal error
 [Something went wrong inside Tor, so that the client's
 request couldn't be fulfilled.]

 552 Unrecognized entity
 [A configuration key, a stream ID, circuit ID, event,
 mentioned in the command did not actually exist.]

 553 Invalid configuration value
 [The client tried to set a configuration option to an
 incorrect, ill-formed, or impossible value.]

 554 Invalid descriptor

 555 Unmanaged entity

 650 Asynchronous event notification
 */
typedef NS_ENUM(NSInteger, TORControlReplyCode) {
    TORControlReplyCodeOK                               = 250,
    TORControlReplyCodeOperationWasUnnecessary          = 251,
    TORControlReplyCodeResourceExhaused                 = 451,
    TORControlReplyCodeSyntaxErrorProtocol              = 500,
    TORControlReplyCodeUnrecognizedCommand              = 510,
    TORControlReplyCodeUnimplementedCommand             = 511,
    TORControlReplyCodeSyntaxErrorInCommandArgument     = 512,
    TORControlReplyCodeUnrecognizedCommandArgument      = 513,
    TORControlReplyCodeAuthenticationRequired           = 514,
    TORControlReplyCodeBadAuthentication                = 515,
    TORControlReplyCodeUnspecifiedTorError              = 550,
    TORControlReplyCodeInternalError                    = 551,
    TORControlReplyCodeUnrecognizedEntity               = 552,
    TORControlReplyCodeInvalidConfigurationValue        = 553,
    TORControlReplyCodeInvalidDescriptor                = 554,
    TORControlReplyCodeUnmanagedEntity                  = 555,
    TORControlReplyCodeAsynchronousEventNotification    = 650
};

#endif /* TORControlReplyCode_h */
