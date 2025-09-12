//
//  TORLogging.h
//  Tor
//
//  Created by Benjamin Erhart on 9/9/17.
//

#import <Foundation/Foundation.h>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(* tor_log_cb)(os_log_type_t severity, const char* msg);

extern void TORInstallEventLogging(void);

extern void TORInstallEventLoggingCallback(tor_log_cb cb);

extern void TORInstallTorLogging(void);

extern void TORInstallTorLoggingCallback(tor_log_cb cb);

NS_ASSUME_NONNULL_END
