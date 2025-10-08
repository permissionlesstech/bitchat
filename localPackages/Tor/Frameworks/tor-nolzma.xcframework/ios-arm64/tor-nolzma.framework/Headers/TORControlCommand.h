//
//  TORControlCommand.h
//  Tor
//
//  Created by Denis Kutlubaev on 30.03.2021.
//

#ifndef TORControlCommand_h
#define TORControlCommand_h

/** TOR control commands
 https://github.com/torproject/torspec/blob/master/control-spec.txt
 */
static NSString * const TORCommandAuthenticate      = @"AUTHENTICATE";
static NSString * const TORCommandSignalShutdown    = @"SIGNAL SHUTDOWN";
static NSString * const TORCommandResetConf         = @"RESETCONF";
static NSString * const TORCommandSetConf           = @"SETCONF";
static NSString * const TORCommandSetEvents         = @"SETEVENTS";
static NSString * const TORCommandGetInfo           = @"GETINFO";
static NSString * const TORCommandSignalReload      = @"SIGNAL RELOAD";
static NSString * const TORCommandSignalNewnym      = @"SIGNAL NEWNYM";
static NSString * const TORCommandCloseCircuit      = @"CLOSECIRCUIT";

#endif /* TORControlCommand_h */
