#!/usr/bin/env tclsh
# ijbridge.tcl - Copyright (C) 2004 Pat Thoyts <patthoyts@users.sf.net>
#
# This implements a bridge between a Jabber Multi-User Chat and an IRC
# channel.
#
# The IRC portions of this have come from ircbridge.
#
# -------------------------------------------------------------------------
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.
# -------------------------------------------------------------------------

package require jlib;                   # jabberlib
package require browse;                 # jabberlib
package require muc;                    # jabberlib
package require wrapper;                # jabberlib
package require sha1;                   # tcllib
package require log;                    # tcllib
package require irc 0.4;                # tcllib

namespace eval client {}

namespace eval ::ijbridge {

    variable version 1.0.1
    variable rcsid {$Id: ijbridge.tcl,v 1.18 2007/02/02 00:07:13 patthoyts Exp $}

    # This array MUST be set up by reading the configuration file. The
    # member names given here define the settings permitted in the 
    # config file.
    # This script will not work by default - you MUST provide suitable 
    # connection details.
    #
    variable Options
    if {![info exists Options]} {
        array set Options {
            JabberServer   {}
            JabberPort     5222
            JabberUser     {}
            JabberPassword {}
            JabberResource ijbridge
            Conference     {}
            ConferenceNick {}
            
            IrcServer      irc.freenode.net
            IrcPort        6667
            IrcUser        {}
            IrcChannel     {}
            IrcNickPasswd  {}
            StatisticsFile {}
        }
    }

    # State variable used in rate-limiting communications with IRC.
    variable Limit
    if {![info exists Limit]} {
        array set Limit {}
    }

    # Used to maintain a view of the users currently connected to IRC.
    variable IrcUserList
    if {![info exists IrcUserList]} {
        set IrcUserList [list]
    }

    variable statid
    variable stats
    if {![info exists stats]} {
        array set stats {}
    }
}

# -------------------------------------------------------------------------

# ijbridge::connect --
#
#	Connect to the jabber server. The server details are help in the
#	Options array. However, it is possible to create the socket through
#	a proxy too, so the connection server and port may be given here
#	too. For example, if you set up sockspy to forward localhost:5222
#	to your jabber server, then you would give 'connect localhost 5222'
#	to set up this connection.
#
proc ::ijbridge::connect {{server {}} {port {}}} {
    variable Options
    variable conn
    array set conn {}
    
    # If roster is unset this is a new connection.
    if {![info exists conn(roster)]} {
        log::log debug "Creating new jabber client instance"
        set conn(roster) [roster::roster [namespace origin OnRoster]]
        set conn(jabber) [jlib::new $conn(roster) \
                              [namespace origin OnClient] \
                              -iqcommand       [namespace origin OnIq] \
                              -messagecommand  [namespace origin OnMessage] \
                              -presencecommand [namespace origin OnPresence]]

        # override the jabberlib version info query
        $conn(jabber) iq_register get jabber:iq:version \
            [namespace origin OnVersion] 40

        if {$server == {}} { set server $Options(JabberServer) }
        if {$port == {}} { set port $Options(JabberPort) }
        set conn(server) $server
        set conn(port) $port
    }

    set conn(sock) [socket $conn(server) $conn(port)]
    $conn(jabber) setsockettransport $conn(sock)    
    $conn(jabber) openstream $Options(JabberServer) \
        -cmd [namespace current]::OnConnect -socket $conn(sock)

    return
}

# ijbridge::disconnect --
#
#	Close the jabber stream and remove the socket from our state array.
#
proc ::ijbridge::disconnect {} {
    variable conn
    $conn(jabber) closestream
    unset conn(sock)
}

# ijbridge::reconnect --
#
#	Handle reconnection to the jabber server. This maintains the current
#	Jabber session details, but reconnects the underlying transport.
#	We try in increments of 5 seconds up to a maximum of 50 seconds
#	delay until we get connected.
#
proc ::ijbridge::reconnect {} {
    variable conn
    set retry [incr conn(retry)]
    if {$retry > 10} {set conn(retry) 10}
    set delay [expr {5000 * $conn(retry)}]
    log::log warning "jabber client disconnected. retry in ${delay}ms"
    after $delay {if {[catch {::ijbridge::connect}]} {::ijbridge::reconnect}}
}

proc ::ijbridge::LoadStats {} {
    variable Options
    variable stats
    catch {unset stats}
    if {[file exists $Options(StatisticsFile)]} {
        set f [open $Options(StatisticsFile) r]
        while {[gets $f line] > 0} {
            set stats([lindex $line 0]) [lindex $line 1]
        }
        close $f
    }
}

proc ::ijbridge::UpdateStats {who length} {
    variable stats
    if {![info exists stats($who,c)]} {
        set stats($who,c) [expr {wide($length)}]
        set stats($who,l) 1
    } else {
        set stats($who,c) [expr {wide($stats($who,c)) + $length}]
        set stats($who,l) [expr {wide($stats($who,l)) + 1}]
    }
    set stats($who,t) [clock seconds]
}

# Dump stats to file and schedule another dump in 1 hour
proc ::ijbridge::DumpStats {{settimer 1}} {
    variable Options
    variable stats
    variable statid
    catch {after cancel $statid}
    if {[string length $Options(StatisticsFile)] > 0} {
        set f [open $Options(StatisticsFile) w]
        foreach name [lsort [array names stats]] {
            puts $f "$name $stats($name)"
        }
        close $f
        set statid [after 3600000 ::ijbridge::DumpStats]
    }
}

# ijbridge::OnConnect --
#
#	Called when the Jabber stream is initialised. Here we authenticate
#	with the Jabber server.
#
proc ::ijbridge::OnConnect {token args} {
    variable Options
    variable conn
    
    log::log debug "OnConnect $token $args"
    array set info $args
    set conn(info) $args
    set conn(id) [$token send_auth \
                      $Options(JabberUser) $Options(JabberResource) \
                      [namespace origin OnLogin] \
                      -password $Options(JabberPassword)]
    #-digest [sha1::sha1 $info(id)$JabberPassword]]
}

# ijbridge::OnLogin --
#
#	This is called once we have sent our authentication details.
#	If we succeeded then we set our default presence to invisible and 
#	then join the conference.
#
proc ::ijbridge::OnLogin {token type query} {
    variable Options
    variable conn
    switch -exact -- $type {
        result {
            $token send_presence -type available
            set conn(muc) [jlib::muc::new $token]
            $conn(muc) enter $Options(Conference) $Options(ConferenceNick) \
                -command [namespace origin OnMucEnter]
        }
        error {
            log::log error "Failed to login! \"$query\""
            return -code error "Failed to login! \"$query\""
        }
        default {
            log::log debug "OnLogin: $token $type $query"
        }
    }
}

# ijbridge::OnMucEnter --
#
#	Called when we enter the conference.
#
proc ::ijbridge::OnMucEnter {muc type args} {
    variable Options
    log::log debug "OnMucEnter $muc $type $args"
}

# ijbridge::OnVersion --
#
#	Override the jabberlib response to the jabber:iq:version
#	query and return something a bit more specific.
#
proc ::ijbridge::OnVersion {token from subiq args} {
    global tcl_platform
    variable version

    array set a {-id {}}
    array set a $args
    set opts {}
    if {$a(-id) ne {}} { lappend opts -id $a(-id) }
    set os $tcl_platform(os)
    if {[info exists tcl_platform(osVersion)]} {
        append os " $tcl_platform(osVersion)"
    }
    append os "/Tcl [info patchlevel]"
    lappend opts -to $from
    set subtags [list  \
                     [wrapper::createtag name    -chdata "ijbridge"]  \
                     [wrapper::createtag version -chdata $version]  \
                     [wrapper::createtag os      -chdata $os] ]
    set xmllist [wrapper::createtag query -subtags $subtags  \
                     -attrlist {xmlns jabber:iq:version}]
    eval {jlib::send_iq $token "result" [list $xmllist]} $opts

    # Tell jlib's iq-handler that we handled the event.
    return 1
}

# ijbridge::OnClient --
#
#	This callback is registered when we create the Jabber client stream
#	and is called whenever anything occurs to affect the client.
#	This covers network faults or hiccups and errors in the stream.
#	Some of these may be recoverable by reconnecting.
#
proc ::ijbridge::OnClient {token cmd args} {
    variable conn
    switch -exact -- $cmd {
        connect {
            log::log debug "jabber client connected"
            set conn(retry) 0
        }
        disconnect {
            catch {disconnect}
            reconnect
        }
        networkerror {
            log::log error "network error $args"
            catch {disconnect}
            reconnect
        }
        streamerror {
            if {[catch {
                array set a $args
                log::log error $a(-errormsg)
            }]} {
                log::log error $args 
            }
            catch {disconnect}
            reconnect
        }
        default {
            log::log debug "OnClient $token $cmd $args"
        }
    }
}

# ijbridge::OnRoster --
#
#	Roster management callback.
#
proc ::ijbridge::OnRoster {roster type {jid {}} args} {
    variable conn
    log::log debug "OnRoster: $roster $type $jid $args"
    switch -exact -- $type {
        presence {
        }
        default {
        }
    }
}

# ijbridge::OnIq --
#
#	This is called to handle Jabber querys.
#
proc ::ijbridge::OnIq {token type args} {
    if {[catch {
        switch -exact -- $type {
            get {
                eval [linsert $args 0 OnIqGet $token]
            }
            set {
                eval [linsert $args 0 OnIqSet $token]
            }
        }
    } err]} {
        log::log error $err
    }
}
proc ::ijbridge::OnIqGet {token args} {
    variable Options
    variable conn
    log::log debug "iq: $token get $args"
    array set a {-query {} -id {} -from {} -to {}}
    array set a $args
    set iqns [wrapper::getattribute $a(-query) xmlns]
    set iqnode [wrapper::getattribute $a(-query) node]
    set r {}
    switch -exact -- $iqns {
        "http://jabber.org/protocol/disco#info" {
            if {$iqnode eq {}} {
                lappend p [list identity [list name "IRC-Jabber Bridge" category bridge type irc] 1 {} {}]
                lappend p [list feature {var jabber:iq:version} 1 {} {}]
                lappend p [list feature {var iq} 1 {} {}] [list feature {var message} 1 {} {}]
                lappend p [list feature {var "http://jabber.org/protocol/disco#info"} 1 {} {}]
                lappend p [list feature {var "http://jabber.org/protocol/disco#items"} 1 {} {}]
                lappend p [list feature {var http://jabber.org/protocol/commands} 1 {} {}]
                lappend c [list query [list xmlns $iqns] 0 {} $p]
                set r [list iq [list xmlns jabber:client type result \
                                    id $a(-id) to $a(-from) from $a(-to)] 0 {} $c]
            } elseif {$iqnode eq "http://jabber.org/protocol/commands"} {
                lappend p [list identity [list name "IJBridge Bot commands"\
                                              category automation type command-list] 1 {} {}]
                lappend c [list query [list xmlns $iqns type $iqnode] 0 {} $p]
                set r [list iq [list xmlns jabber:client type result \
                                    id $a(-id) to $a(-from) from $a(-to)] 0 {} $c]
            } elseif {$iqnode eq "help"} {
                lappend p [list identity [list name "Help"  category automation type command-node] 1 {} {}]
                lappend p [list feature {var http://jabber.org/protocol/commands} 1 {} {}]
                lappend p [list feature {var jabber:x:data} 1 {} {}]
                lappend c [list query [list xmlns $iqns node $iqnode] 0 {} $p]
                set r [list iq [list xmlns jabber:client type result \
                                    id $a(-id) to $a(-from) from $a(-to)] 0 {} $c]                
            } else {
                set r [IqError $iqns forbidden $a(-id) $a(-to) $a(-from) cancel 403]
            }
        }
        "http://jabber.org/protocol/disco#items" {
            switch -exact -- $iqnode {
                http://jabber.org/protocol/commands {
                    set JID $Options(JabberUser)@$Options(JabberServer)
                    lappend p [list item [list jid $JID node help name "Help"] 1 {} {}]
                    lappend c [list query [list xmlns $iqns node $iqnode] 0 {} $p]
                    set r [list iq [list xmlns jabber:client type result \
                                        id $a(-id) to $a(-from) from $a(-to)] 0 {} $c]
                }
                default {
                    set r [IqError $iqns feature-not-implemented \
                               $a(-id) $a(-to) $a(-from) cancel 501]
                }                    
            }
        }
        jabber:iq:version {
            variable version
            lappend p [list name {} 0 "IRC-Jabber Bridge" {}]
            lappend p [list version {} 0 $version {}]
            lappend p [list os {} 0 "Tcl/[info patchlevel]" {}]
            lappend c [list query [list xmlns $query] 0 {} $p]
            set r [list iq [list xmlns jabber:client type result id $id\
                                to $a(-from) from $a(-to)] 0 {} $c]
        }
        default {
            set r [IqError $iqns feature-not-implemented \
                       $a(-id) $a(-to) $a(-from) cancel 501]
        }
    }
    if {$r ne {}} {
        jlib::send $conn(jabber) $r
    }
}

proc ::ijbridge::OnIqSet {token args} {
    variable Options
    variable conn
    log::log debug "iq: $token set $args"
    array set a {-query {} -id {} -from {} -to {}}
    array set a $args
    set iqns [wrapper::getattribute $a(-query) xmlns]
    set iqnode [wrapper::getattribute $a(-query) node]
    set r {}
    switch -exact -- $iqns {
        default {
            set r [IqError $iqns feature-not-implemented \
                       $a(-id) $a(-to) $a(-from) cancel 501]
        }
    }
    if {$r ne {}} {
        jlib::send $conn(jabber) $r
    }
}

proc ::ijbridge::IqError {query type id self requester {etype cancel} {ecode 501}} {
    lappend p [list $type {xmlns urn:ietf:params:xml:ns:xmpp-stanzas} 1 {} {}]
    lappend qr [list query [list xmlns $query] 1 {} {}]
    lappend qr [list error [list type $etype code $ecode] 0 {} $p]
    set ra [list xmlns jabber:client type error id $id to $requester from $self]
    set rsp [list iq $ra 0 {} $qr]
}

# ijbridge::OnMessage --
#
#	This is the core procedure. This is called when Jabber messages are
#	recieved. 'groupchat messages are from the conference and these we 
#	re-transmit to IRC using the 'xmit' procedure.
#	Some processing occurs here. IRC doesn't accept multi-line posts
#	so we break those up. We also avoid re-sending messages that we
#	have sent from IRC.
#	
#	'chat' messages are messages sent to ijbridge specifically. These
#	are used as commands to the bridge.
# 
proc ::ijbridge::OnMessage {token type args} {
    if {[catch {eval [linsert $args 0 OnMessageBody $token $type]} msg]} {
        log::log error $msg
    }
}
proc ::ijbridge::OnMessageBody {token type args} {
    variable Options
    variable conn
    variable IrcUserList

    switch -exact -- $type {
        groupchat {
            # xmit to irc
            log::log debug "groupchat --> $args"
            array set a {-body {} -from {}}
            array set a $args
            set mynick [$conn(muc) mynick $Options(Conference)]
            set myid $Options(Conference)/$mynick
            if {[info exists a(-from)] && [string equal $a(-from) $myid]} {
                log::log debug "avoid resend"
            } else {

                # This permits us to issue the last 30 seconds of Jabber room
                # chat to the IRC channel on connection. In general this is
                # probably not helpful, hence it is disabled.
                if {0 && [info exists a(-x)]} {
                    foreach chunk $a(-x) {
                        if {[lsearch -exact [wrapper::getattrlist $chunk] \
                                 jabber:x:delay] != -1} {
                            set stamp [wrapper::getattribute $chunk stamp]
                            if {[clock seconds]-[clock scan $stamp -gmt 1] > 30} {
                                # We don't xmit history items.
                                log::log debug "avoid xmit history items > 30s old"
                                return
                            }
                        }
                    }
                }

                set nickndx [string first / $a(-from)]
                set nick [string range $a(-from) [incr nickndx] end]
                set emote [string match /me* $a(-body)]
                if {$emote} {
                    set a(-body) [string range $a(-body) 4 end]
                }
                foreach line [split $a(-body) \n] {
                    UpdateStats $nick [string length $line]
                    if {$emote} {
                        xmit "PRIVMSG $::client::channel :\001ACTION $nick $line\001"
                    } else {
                        xmit "PRIVMSG $::client::channel :<$nick> $line"
                    }
                }
            }
        }
        chat {
            array set a {-body {} -from {}}
            array set a $args
            log::log debug "chat --> $args"
            switch -glob -- $a(-body) {
                HELP* - help* {
                    send -user $a(-from) \
                        -id $Options(Conference)/$Options(JabberUser) \
                        "\n help       show this message\n\
                         names      returns a list of all IRC users\n\
                         version    returns the bridge code version\n\
                         rcsid      returns the RCS version of this file\n\
                         stats      display chatroom statistics\n\
                         last nick  how long since this user spoke\n\
                         whois nick get irc WHOIS information\n\
                         kick nick  kick irc user"
                }
                WHOIS* - whois* {
                    set ::client::whois(caller) $a(-from)
                    xmit "USERHOST [string range $a(-body) 6 end]"
                    xmit "WHOIS [string range $a(-body) 6 end]"
                }
                NAMES* - names* {
                    xmit "NAMES $::client::channel"
                    send -user $a(-from) \
                        -id $Options(Conference)/$Options(JabberUser) \
                        $IrcUserList
                }
                VERSION - version {
                    send -user $a(-from) $::ijbridge::version
                }
                RCSID - rcsid {
                    send -user $a(-from) $::ijbridge::rcsid
                }
                KICK* - kick* {
                    log::log notice $a(-body)
                    set user [lindex $a(-body) 1]
                    xmit "KICK $::client::channel $user"
                    send -user $a(-from) "Kicking $user."
                }
                STATS - stats - STATISTICS - statistics {
                    # This is not done as a bot command as it floods irc
                    # too much and gets the bot kicked by freenode.
                    variable stats
                    set m [format {%- 30s %- 18s % 8s% 10s} \
                               "User" "Last seen" "Lines" "Chars"]
                    foreach u [lsort [array names stats *,t]] {
                        set u [string range $u 0 end-2]
                        append m "\n" [format {%- 30s %- 18s % 8d% 10d} \
                                           [string range $u 0 30] \
                                           [delta $stats($u,t)] \
                                           $stats($u,l) $stats($u,c)]
                    }
                    send -user $a(-from) $m
                }
                LAST* - last* {
                    send -user $a(-from) [Bot_last $a(-from) $a(-body)]
                }
                /msg* {
                    if {[regexp {^/msg (\w+) (.*)$} $a(-body) -> who msg]} {
                        set nickndx [string first / $a(-from)]
                        set nick [string range $a(-from) [incr nickndx] end]
                        xmit "PRIVMSG $who :$nick whispers $msg"
                    } else {
                        send -user $a(-from) \
                            -id $Options(Conference)/$Options(JabberUser) \
                            "Try: /msg nick message"
                    }
                }
            }
        }
	normal {
	    array set a {-subject {} -from {}}
	    array set a $args
	    log::log debug "normal --> $args"
	    switch -- $a(-subject) {
		IrcUserList {
		    send -user $a(-from) -type normal \
                        -subject IrcUserList $IrcUserList
		}
	    }
	}
        error -
        default {
            log::log debug "msg: $token $type $args"
        }
    }
}

# ijbridge::OnPresence --
#
#	Called when we recieve a Jabber presence notification.
#
proc ::ijbridge::OnPresence {token type args} {
    log::log debug "prs: $token $type $args"
}

# ijbridge::IrcToJabber --
#
#	This procedure is called to copy messages from the IRC channel
#	to the Jabber conference. Currently the Tcl channel is also
#	bridging to a webchat with something called 'ircbridge' and
#	this is using the nick 'azbridge'. To avoid having excessive
#	nick prefixes, we trim this one here.
#
proc ::ijbridge::IrcToJabber {who msg emote} {
    variable Options
    variable xmlmap
    if {![info exists xmlmap]} {
        set xmlmap {}
        for {set n 0} {$n < 32} {incr n} {
            if {$n == 9 || $n == 10 || $n == 13} continue
            lappend xmlmap [format %c $n] [format "&#x%x;" $n]
        }
    }

    if {[string equal $who "azbridge"] || [string equal $who "ircbridge"]} {
        regexp {^<(.*?)> (.*)$}  $msg -> who msg
        set emote [regexp {^\*{1,3} (\w+) (.*)$} $msg -> who msg]
    }

    if {[string match -nocase "${::client::nick}\[:,;. |\]*" $msg]} {
        set n [string length ${::client::nick}]
        return [BotCommand $::client::channel $who [string range $msg [incr n] end]]
    }

    set msg [string map $xmlmap $msg]
    UpdateStats $who [string length $msg]

    if {$emote} {
        ijbridge::send -id "$Options(Conference)/$who" "* $who $msg"
    } else {
        ijbridge::send -id "$Options(Conference)/$who" "<$who> $msg"
    }
}

# Here we can implement some bot commands. If we don't recognise a command
# then post them a bot message.
# eg:
#  ijchain tip 100'  replies with url and subject of tip.
#  ijchain bug 10123:  replies with url or bug
#  ijchian what|what is maybe lookup text on wiki and feed url
#  ijchain help
#  ijchain faq
proc ::ijbridge::BotCommand {rt who msg} {
    log::log debug "BotCmd: '$who' '$msg'"
    set cmd [lindex $msg 0]
    if {[llength [info commands ::ijbridge::Bot_${cmd}]] != 0} {
        set r [catch {::ijbridge::Bot_${cmd} $who $msg} err]
        if {$r} { puts "ERROR: $err" } else {BotSay $rt $err}
    } else {
        BotSay $rt [Bot_unknown $who $msg]
    }
}

proc ::ijbridge::BotSay {rt msg} {
    variable Options
    foreach line [split $msg \n] {
        xmit "PRIVMSG $rt :$line"
    }
    if {$rt eq $::client::channel} {
        send "<$Options(ConferenceNick)> $msg"
    }
}

proc ::ijbridge::Bot_help {who msg} {
    set notice "Bot commands: "
    foreach cmd [info commands ::ijbridge::Bot_*] {
        set cmd [string range $cmd 16 end]
        append notice $cmd " "
    }
    return $notice
}

proc ::ijbridge::Bot_test {who msg} {
    return "$who just tested the answer bot."
}

proc ::ijbridge::Bot_eggdrop {who msg} {
    return "This is not an eggdrop channel. Try \#eggtcl on efnet or see http://wiki.tcl.tk/eggdrop"
}

proc ::ijbridge::Bot_names {who msg} {
    variable Options
    variable conn
    set names {}
    foreach jid [$conn(muc) participants $Options(Conference)] {
        lappend names [jid resource $jid]
    }
    return [lsort $names]
}

proc ::ijbridge::Bot_last {who msg} {
    variable stats
    set user [string trim [lindex $msg 1]]
    if {[info exists stats($user,t)]} {
        set m "$user last seen [delta $stats($user,t)]"
    } else {
        set m "$user has never been seen"
    }
    return $m
}

proc ::ijbridge::Bot_unknown {who msg} {
    variable Options
    set notice "$::client::nick is a bot connecting this\
                $::client::channel to a Jabber chat-room \
                (xmpp:$Options(Conference)).\
                When you see \"<${::client::nick}> <nickname> ...\"\
                this really means that <nickname> said something,\
                not me!"
    return $notice
}

# ::ijbridge::delta --
#
#       Returns the time difference between the given and current time
#       as an english string.
#
proc ::ijbridge::delta {time} {
    set r $time
    catch {
        set delta [expr {[clock seconds] - $time}]
        if {$delta < 60} {
            set r "$delta secs ago"
        } elseif {$delta < 3600} {
            set r "[expr {$delta / 60}] mins ago"
        } elseif {$delta < 86400} {
            set r "[expr {$delta / 3600}] hours ago"
        } else {
            set r "[expr {$delta / 86400}] days ago"
        }
    }
    return $r
}

# ijbridge::jid --
#
#	Utility function to manage access to parts of a JID
#
proc ::ijbridge::jid {part jid} {
    set r {}
    if {[regexp {^(?:([^@]*)@)?([^/]+)(?:/(.+))?} $jid \
        -> node domain resource]} {
        switch -exact -- $part {
            node      { set r $node }
            domain    { set r $domain }
            resource  { set r $resource }
            !resource { set r ${node}@${domain} }
            jid       { set r $jid }
            default {
                return -code error "invalid part \"$part\":\
                    must be one of node, domain, resource or jid."
            }
        }
    }
    return $r
}

# ijbridge::send --
#
#	This procedure sends a message to the Jabber conference.
#	-user is the jid of the recipient or if not specified then the
#	message is sent to the conference.
#
proc ::ijbridge::send {args} {
    variable Options
    variable conn
    array set opts { user {} -xlist {} -type chat -id {} -from {}}
    while {[string match -* [set option [lindex $args 0]]]} {
        switch -exact -- $option {
            -user    { set opts(user) [Pop args 1] }
            -id      { set opts(-id) [Pop args 1] }
            -from    { set opts(-from) [Pop args 1] }
            -type    { set opts(-type) [Pop args 1] }
            -subject { set opts(-subject) [Pop args 1] }
            --       { Pop args ; break }
        }
        Pop args
    }
    if {[llength $args] != 1} {
        return -code error "wrong \# args:\
            should be \"send ?option value? message\""
    }
    if {[string length $opts(-id)] < 1} {
        set opts(-id) $conn(id)
    }
    if {[string length $opts(user)] < 1} {
        set opts(user) $Options(Conference)
        set opts(-type) groupchat
    }
    
    log::log debug "send: [lindex $args 0]"
    eval [linsert [array get opts -*] 0 $conn(jabber) \
              send_message $opts(user) -body [lindex $args 0]]
}

# ijbridge::xmit --
#
#	This is where we send messages to the IRC channel. IRC requires 
#	rate limiting. A client can be kicked for sending too much in
#	too short a period so here we deal with this.
#
proc ::ijbridge::xmit {str} {
    variable Options
    variable Limit
    # if we are over the sending limit just push line into the queue
    if { $Limit(queue) != "" } {
        ::log::log debug "appending to queue"
        lappend Limit(queue) $str
        return
    }
    # count the number of lines per second
    if { ([clock seconds] - $Limit(last)) < 1 } {
        incr Limit(lines)
        ::log::log debug "lines: $Limit(lines)"
    } else {
        # remember the last time we sent a line
        set Limit(last) [clock seconds]
        set Limit(lines) 0
    }
    # if we are over the line limit kick off the queued sends
    if { $Limit(lines) > 4 } {
        ::log::log info "flood started"
        lappend Limit(queue) $str
        after 1000 [namespace origin XmitFromQueue]
        return
    }
    $client::cn send $str
}

# ijbridge::XmitFromQueue --
#
#	If we had to limit messages sent from 'xmit' then we handle the
#	queued messages from here on a timer.
#
proc ::ijbridge::XmitFromQueue {} {
    variable Options
    variable Limit
    # return if the queue is empty
    if { [string length [set str [lindex $Limit(queue) 0]]] < 1 } {
        set Limit(last) 0
        ::log::log info "flood ended"
        return
    }
    set Limit(queue) [lreplace $Limit(queue) 0 0]
    ::log::log debug "sending from queue"
    $client::cn send $str
    # send next line
    after 1000 [namespace origin XmitFromQueue]
}

# ijbridge::Pop --
#
#	Utility function used in option processing.
#
proc ::ijbridge::Pop {varname {nth 0}} {
    upvar $varname args
    set r [lindex $args $nth]
    set args [lreplace $args $nth $nth]
    return $r
}

# ijbridge::LoadConfig --
#
#	This procedure reads a text file and updates the Options array
#	from the contents. Comments and blank lines are ignored. All 
#	other lines must be a list of two elements, the first element 
#	must be an item in the Options array.
#
proc ::ijbridge::LoadConfig {} {
    variable Options
    set conf [file normalize [info script]]
    set base [file rootname [file tail $conf]].conf
    set conf [file join [file dirname $conf] $base]
    if {[file exists $conf]} {
        set f [open $conf r]
        set n 0
        while {![eof $f]} {
            gets $f line
            string trim $line
            if {[string match "#*" $line]} { incr n ; continue }
            if {[string length $line] < 1} { incr n ; continue }
            if {[llength $line] != 2} {
                return -code error "invalid config line $n: \"$line\""
            }
            if {![info exists Options([lindex $line 0])]} {
                return -code error "invalid config option\
                \"[lindex $line 0]\" at line $n"
            }
            set Options([lindex $line 0]) [lindex $line 1]
            incr n
        }
        close $f
    } else {
        log::log warning "no configuration file found!"
    }
    return
}

# -------------------------------------------------------------------------

# create a server connection and set up associated events

proc client::create { server port nk chan } {
    variable channel $chan
    variable nick $nk
    variable whois
    array set whois {caller "" realname "" url "" channels "" status ""}
    variable cn [::irc::connection]

    registerhandlers

    $cn registerevent EOF "
        ::log::log notice \"Disconnected from IRC\"
        ::client::connect \$::client::cn $server $port
    "

    connect $cn $server $port
}

proc client::registerhandlers {} {
    variable cn

    $cn registerevent 001 {
        # RPL_WELCOME
        log::log notice "Joining $::client::channel"
        set ::client::nick [target]
        cmd-join $::client::channel
    }

    $cn registerevent 433 {
        # ERR_NICKNAMEINUSE
        if { [lindex [additional] 0] == $::client::nick } {
            cmd-send "NICK [string trimright $::client::nick 0123456789][string range [expr rand()] end-2 end]"
        }
    }

    $cn registerevent 353 {
        # RPL_NAMEREPLY
	#List of online users sent on channel join
        variable ::ijbridge::IrcUserList
	::log::log debug "UsersOnline [msg]"
	set IrcUserList \
		[split [string map {@ "" % "" + ""} [string trim [msg]]] " "]
	foreach bridge {ircbridge azbridge ijbridge ijchain} {
	    set IrcUserList \
		    [lsearch -all -inline -exact -not $IrcUserList $bridge]
	}
        # Ask Chanserv to op us.
        cmd-send "PRIVMSG Chanserv :op $::client::channel $::client::nick"
    }

    $cn registerevent 376 {
        # RPL_ENDOFMOTD
        variable ::ijbridge::Options
        if {[catch {
            if {[string length $Options(IrcNickPasswd)] > 0} {
                cmd-send "PRIVMSG nickserv :IDENTIFY $Options(IrcNickPasswd)"
            }
        } err]} { puts stderr $err }
    }
   
    # WHOIS handling from Jabber user 
    $cn registerevent 311 {set ::client::whois(realname) [msg]}
    $cn registerevent 312 {set ::client::whois(url) [msg]}
    $cn registerevent 319 {set ::client::whois(channels) [msg]}
    $cn registerevent 320 {set ::client::whois(status) [msg]}
    $cn registerevent 302 {set ::client::whois(host) [msg]}
    $cn registerevent 318 {
        variable ::client::whois
        if {[string length $whois(caller)] > 0} {
            set info "Realname: $whois(realname)\n"
            append info "Host: $whois(host)\n"
            append info "Channels: $whois(channels)\n"
            append info "Status: $whois(status)"
            ::ijbridge::send -user $whois(caller) $info
        }
        array set whois {caller "" realname "" url "" channels "" status ""}
    }
    $cn registerevent 401 {
        variable ::client::whois
        if {[string length $whois(caller)] > 0} {
            ::ijbridge::send -user $whois(caller) [msg]
            set whois(caller) ""
        }
    }
    
    $cn registerevent defaultcmd {
	::log::log notice "[action]:[msg]"
    }

    $cn registerevent defaultnumeric {
	::log::log notice "[action]:[target]:[msg]"
    }

    $cn registerevent defaultevent {
        switch -exact -- [action] {
            PONG {}
            KICK {
                #::ijbridge::send "[who] kicked someone \"[msg]\""
                ::log::log notice "[action]:[who]:[target]:[msg]" 
            }
            MODE -
            default {
                ::log::log notice "[action]:[who]:[target]:[msg]" 
            }
        }
    }

    $cn registerevent PRIVMSG {
        if {[catch {
            if { [string equal [target] $client::channel] } {
                set emote 0
                set msg [msg]
                if { [string match "\001*\001" [msg]] } {
                    if { [regexp {^\001ACTION (.+)\001$} [msg] -> msg] } {
                        set emote 1
                    }
                }
                ijbridge::IrcToJabber [who] $msg $emote
            } elseif {[string equal [target] $client::nick]} {
                ::ijbridge::BotCommand [who] [who] [msg]
            } else {
                log::log debug "[action]:[who]:[target]:[msg]"
            }
        } err]} { log::log notice $err }
    }

    $cn registerevent PART {
        variable ::ijbridge::IrcUserList
	if { [target] eq $client::channel && [who] ne $client::nick } {
	    set IrcUserList \
		    [lsearch -all -inline -exact -not $IrcUserList [who]]
	    ijbridge::send "*** [who] leaves"
	}

    }

    $cn registerevent JOIN {
        variable ::ijbridge::IrcUserList
	if { [lsearch -exact {ircbridge azbridge ijbridge ijchain} [who]] == -1 \
		&& [who] ne $client::nick } {
	    if { [lsearch -exact $IrcUserList [who]] == -1 } {
		lappend IrcUserList [who]
	    }
	    ijbridge::send "*** [who] joins"
	}
    }

    $cn registerevent NICK {
        variable ::ijbridge::IrcUserList
	if { [who] eq $::client::nick } {
	    set ::client::nick [msg]
	} else {
	    set IrcUserList \
		    [lsearch -all -inline -exact -not $IrcUserList [who]]
	    if { [lsearch -exact $IrcUserList [msg]] == -1 } {
		lappend IrcUserList [msg]
	    }
	    ijbridge::send "*** [who] is now known as [msg]"
	}
    }

    $cn registerevent QUIT {
        variable ::ijbridge::IrcUserList
	if { [who] ne $::client::nick } {
	    set IrcUserList \
		    [lsearch -all -inline -exact -not $IrcUserList [who]]
	    ijbridge::send "*** [who] leaves"
	    if { [who] eq [string trimright $::client::nick 0123456789] } {
		cmd-send "NICK [who]"
	    }
	}
    }
}

# connect to the server and register

proc client::connect {cn server port} {
    variable ::ijbridge::Limit
    variable nick
    # set up variable for rate limiting
    array set Limit [list last [clock seconds] queue {} lines 0]
    ::log::log notice "Connecting to $server on port $port"
    if {[catch {$cn connect $server $port} err]} {
        ::log::log notice "Could not connect: $err"
        after 10000 [list [namespace current]::connect $cn $server $port]
        return
    }
    $cn user $nick localhost domain "Tcl Jabber-IRC bridge"
    $cn nick $nick
    ping
    ::log::log notice "Connected to $server"
}

proc client::ping {} {
    variable cn
    $cn serverping
    after cancel [namespace current]::ping
    after 20000 [namespace current]::ping
}

proc bgerror {args} {
    global errorInfo
    ::log::log error "BGERROR: [join $args]"
    ::log::log error "ERRORINFO: $errorInfo"
}

#::irc::config debug 0

# -------------------------------------------------------------------------

# ijbridge::ReadControl --
#
#	Reads commands from stdin and evaluates them. This permits
#	us to issue commands to the server while it is still 
#	running. Suitable commands are ijbridge::presence and
#	ijbridge::say or ijbridge::xmit.
#
proc ::ijbridge::ReadControl {chan} {
    variable Control
    if {![info exists Control]} {set Control {}}
    if {[eof $chan]} {
        puts stderr "!! EOF $chan"
    }
    append Control [read $chan]
    if {[info complete $Control]} {
        set code [catch {uplevel \#0 $Control} res]
        unset Control
        if {$code} {set ochan stderr} else {set ochan stdout}
        puts $ochan $res
    }
}

# -------------------------------------------------------------------------

log::lvSuppressLE emerg 0
log::lvSuppressLE debug 1

proc Main {args} {
    global tcl_platform tcl_interactive tcl_service tk_version
    ::ijbridge::LoadConfig
    ::ijbridge::LoadStats

    if {[string length $ijbridge::Options(JabberServer)] < 1} {
        puts "Error: you MUST provide some configuration information in the\
            ijbridge.conf file. See ijbridge.conf.sample"
        exit 1
    }

    # Setup control stream.
    if {$tcl_platform(platform) eq "unix" \
            && [llength [info commands tkcon]] == 0} {
        set tcl_interactive 1; # fake it so we can re-source this file
        puts "Tcl IRC-Jabber bridge $::ijbridge::version started"
        puts -nonewline "Reading control commands from stdin.\n> "
        fconfigure stdin -blocking 0 -buffering line
        fileevent stdin readable [list ::ijbridge::ReadControl stdin]
    }

    # Connect to IRC
    client::create $ijbridge::Options(IrcServer) \
        $ijbridge::Options(IrcPort) \
        $ijbridge::Options(IrcUser) \
        $ijbridge::Options(IrcChannel)
    
    # Connect to Jabber.
    eval [linsert $args 0 ::ijbridge::connect]
    set ::ijbridge::statid [after 3600000 ::ijbridge::DumpStats]
    
    # Loop forever, dealing with Wish or Tclsh
    if {[llength [info commands tkcon]] == 0} {
        if {[info exists tk_version]} {
            if {[tk windowingsystem] eq "win32"} { console show }
            wm withdraw .
            tkwait variable ::forever
        } else {
            # Permit running as a Windows service.
            if {![info exists tcl_service]} {
                vwait ::forever
            }
        }
    }
    
    # Record the statistics to file
    ::ijbridge::DumpStats
}

if {!$tcl_interactive} {
    set r [catch [linsert $argv 0 Main] err]
    if {$r} {puts $errorInfo}
    exit $r
}
