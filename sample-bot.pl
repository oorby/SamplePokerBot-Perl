#!/usr/bin/perl -w

use strict;

use Data::Dumper;
use Getopt::Long;
use LWP::UserAgent;
use JSON;

my $ARG_HTTP_TIMEOUT = 180;
my $ARG_ENDPOINT_HOST = 'mcp.oorby.com';
my $PLAY_ONE_GAME = 1;

die unless GetOptions(
        'host=s'    => \$ARG_ENDPOINT_HOST,
        'timeout=i' => \$ARG_HTTP_TIMEOUT,
);

if (scalar @ARGV < 2) {
        print "usage: $0 botName guid [--host host] [--timeout timeout]\n";
        exit 1;
}

my $GAME_SERVER = "http://$ARG_ENDPOINT_HOST";

my $bot_name = $ARGV[0];
my $guid = $ARGV[1];

my $lastEventId = 'NONE';
my $last_results = undef;

print "joining game...\n";

my $next_action = undef;

while (1) {
	my $results;
	
	if (defined $next_action) {
		print "Submitting action '$next_action'\n";
		$results = take_action($next_action);
	} else {
		print "Polling for next event\n";
		$results = get_next_events();
	}

  my $event_type = $results->{event}->{eventType};
  if ($event_type eq "GameComplete") {
    $GAME_SERVER = "http://$ARG_ENDPOINT_HOST";
    exit 0 if $PLAY_ONE_GAME;
  } else {
    my $newGameServer = $results->{event}->{game}->{gameManagerHost};
    if (defined $newGameServer && $newGameServer ne $GAME_SERVER) {
      print("game server changed to $newGameServer from $GAME_SERVER\n");
      $GAME_SERVER = $newGameServer;
    }
  }

  if ($event_type eq 'ActionRequired') {
    $next_action = decide_next_action($results);
  } else {
    $next_action = undef;
  }
}


sub get_next_events
{
	my $results = endpoint_get("/v1/poker/bots/${bot_name}/next_event");

	print_results($results);

  return $results;
}

sub take_action
{
	my $action = shift;

	my $results = endpoint_post("/v1/poker/bots/${bot_name}/next_event", {
		action => $action
	});

	print_results($results);

  return $results;
}

sub endpoint_get
{
	my $endpoint = shift;
	my $ua = new LWP::UserAgent;

	$ua->timeout($ARG_HTTP_TIMEOUT);
	$ua->env_proxy();

  my $url = "${GAME_SERVER}${endpoint}?devkey=${guid}&eventId=${lastEventId}";

  my $errorCount = 0;
  while (1) {
    my $response = $ua->get($url);

    if ($response->is_success()) {
      $errorCount = 0;
      if ($response->code == 200) {
        my $results = decode_json $response->content();
        $lastEventId = $results->{eventId};
        return $results;
      } else {
        print "Got " . $response->status_line() . ", retrying request\n";
      }
    } else {
      print "Got error: " . $response->status_line() . ", waiting 10 seconds before trying again (error count = $errorCount)\n";
      $errorCount += 1;
      sleep 10;
    }
  }
}

sub endpoint_post
{
    my ($endpoint, $form_data) = @_;

    my $ua = new LWP::UserAgent();

    $ua->timeout($ARG_HTTP_TIMEOUT);
    $ua->env_proxy;

    my $url = "${GAME_SERVER}${endpoint}?devkey=${guid}&eventId=${lastEventId}";
    my $errorCount = 0;
    while (1) {
      my $response = $ua->post($url, $form_data);

      if ($response->is_success()) {
        $errorCount = 0;
        if ($response->code == 200) {
          my $results = decode_json $response->content();
          $lastEventId = $results->{eventId};
          return $results;
        } else {
          print "Got " . $response->status_line() . ", retrying request\n";
        }
      } else {
        print "Got error: " . $response->status_line() . ", waiting 10 seconds before trying again (error count = $errorCount)\n";
        $errorCount += 1;
        sleep 10;
      }
    }
}


# 'UI' helper functions

sub print_results
{
	my $results = shift;

	my $game_id = $results->{event}->{game}->{gameId};
	my $hand_number = $results->{event}->{hand}->{handNumber};

	print "\n\n\n\n\n*** Game $game_id";
  print ", hand $hand_number" if (defined $hand_number);
  print "\n\n";

	$last_results = $results;

	my $event_type = $results->{event}->{eventType};
	my $hand_complete = 0;
	my $game_complete = 0;
	my $action_required = 0;

	if ($event_type eq 'HandComplete') {
		$hand_complete = 1;
		print "(This hand is now complete.)\n\n";
	} elsif ($event_type eq 'GameComplete') {
		$game_complete = 1;
		print "(This game is now complete.)\n\n";
	} elsif ($event_type eq 'ActionRequired') {
		$action_required = 1;

		my $stakes = $results->{event}->{game}->{playerStakes};
		if (defined $stakes) {
			print "Current stakes:\n";

			foreach my $stake (@$stakes) {
				print "  $stake->{botName} -> $stake->{currentStake}";
				print ' (me)' if ($stake->{botName} eq $bot_name);
				print "\n";
			}
			print "\n";
		}
	}



	my $cc_aref = $results->{event}->{hand}->{communityCards}->{cards};
	if (defined $cc_aref && scalar @$cc_aref > 0) {
		print "Cards on the table:\n";
		print_hand(@$cc_aref);
		print "\n";
	}

	my $hole_aref = $results->{event}->{hand}->{hole}->{cards};
	if (defined $hole_aref) {
		print "Your cards:\n";
		print_hand(@$hole_aref);
		print "\n";
	}

	my $avail_aref = $results->{event}->{hand}->{availableActions};
	if (defined $avail_aref && scalar @$avail_aref > 0) {
    print "Available Actions:\n";
		foreach my $action (@$avail_aref) {
			my $key = $action->{action};
			my $cost = $action->{costOfAction};

			my $label = { 'c' => 'call', 'r' => 'raise', 'f' => 'fold' }->{$key};
			$label = 'check' if ($key eq 'c' && $cost == 0);

			print "  $label";
			print " for $cost" if ($cost > 0);
			print "\n";
		}
	} elsif ($hand_complete || $game_complete) {
		my $showdown_holes_aref;

		if ($hand_complete) {
			$showdown_holes_aref = $results->{event}->{hand}->{showdownPlayerHoles};
		} else {
			# game complete
			$showdown_holes_aref = $results->{event}->{lastHand}->{showdownPlayerHoles};
		}

		if (defined $showdown_holes_aref && scalar @$showdown_holes_aref > 0) {
			print "Showdown:\n";
			foreach my $playerHole (@$showdown_holes_aref) {
				my $resultBotName = $playerHole->{botName};
				my $botName = "bot $resultBotName";
				if ($resultBotName eq $bot_name) {
					$botName = "Your"
				}

				my $bothole_aref = $playerHole->{hole}->{cards};
				my $botbesthand_aref = $playerHole->{bestHand}->{cards};

				print "  $botName hole:\n";
				print_hand(@$bothole_aref);

				print "  $botName best hand:\n";
				print_hand(@$botbesthand_aref);
			}
		}

		my $results_aref = $results->{event}->{hand}->{results};
		print "Results:\n";
		my $myChipChange = 0;
		foreach my $handResults (@$results_aref) {
			my $resultBotName = $handResults->{botName};
			my $resultNetChipChange = $handResults->{netStackChange};

			if ($resultBotName eq $bot_name) {
				$myChipChange = $resultNetChipChange;
			} else {
				print "\tbot $resultBotName -> $resultNetChipChange\n";
			}
		}
		print "\tMe -> $myChipChange\n\n";
	}
}

sub print_hand
{
	my @cards = @_;

	foreach my $row (0..5) {
		foreach my $card (@cards) {
			print card_line($card, $row) . " ";
		}
		print "\n";
	}
}

sub card_line
{
	my ($card, $line) = @_;

	my $rank;
	my $suit;
	if ($card =~ /^([2-9TJQKA])([hcsd])$/) {
		$rank = $1;
		$suit = $2;
	} else {
		return ''; # can't parse card
	}

	my ($rank_left, $rank_right);

	if ($rank eq 'T') {
		$rank_left = '10';
		$rank_right = '10';
	} else {
		if ($suit eq 'h') {
			$rank_left = "${rank}_";
		} else {
			$rank_left = "$rank ";
		}
		$rank_right = " $rank";
	}

	my %art = (
		h => [ ".------.", "|${rank_left}  _ |", "|( \\/ )|", "| \\  / |", "|  \\/${rank_right}|", "`------'" ],
		d => [ ".------.", "|${rank_left}/\\  |", "| /  \\ |", "| \\  / |", "|  \\/${rank_right}|", "`------'" ],
		c => [ ".------.", "|${rank_left}_   |", "| ( )  |", "|(_x_) |", "|  Y ${rank_right}|", "`------'" ],
		s => [ ".------.", "|${rank_left}.   |", "| / \\  |", "|(_,_) |", "|  I ${rank_right}|", "`------'" ]
	);

	return $art{$suit}->[$line];
}


# UPDATE THIS METHOD WITH YOUR OWN POKER LOGIC
sub decide_next_action
{
	my $results = shift;

	# make array of possible actions
	my @act = ();

	my $avail_aref = $results->{event}->{hand}->{availableActions};
	die "No available actions" if (!defined $avail_aref);
	foreach my $action (@$avail_aref) {
		push @act, $action->{action};
	}

	my $r = int rand scalar @act;

	print "We are going to $act[$r]\n\n";

	return $act[$r];
}
