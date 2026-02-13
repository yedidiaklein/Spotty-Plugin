package Plugins::Spotty::Connect;

use strict;

use File::Spec::Functions qw(catdir catfile);
use POSIX qw(:sys_wait_h);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::Spotty::AccountHelper;
use Plugins::Spotty::Helper;

my $prefs = preferences('plugin.spotty');
my $serverPrefs = preferences('server');
my $log = logger('plugin.spotty');

my %connectProcesses; # track running processes per client

use constant MONITOR_INTERVAL => 30;
use constant RESTART_DELAY => 5;

sub init {
	my $class = shift;
	
	# Start monitoring timer
	Slim::Utils::Timers::setTimer($class, time() + MONITOR_INTERVAL, \&monitorProcesses);
}

sub shutdown {
	my $class = shift;
	
	Slim::Utils::Timers::killTimers($class, \&monitorProcesses);
	
	# Stop all running processes
	foreach my $client (keys %connectProcesses) {
		$class->stopConnect($client);
	}
}

sub startConnect {
	my ($class, $client) = @_;
	
	return unless $client;
	
	# Check if Connect is enabled globally and for this client
	return unless $prefs->get('enableSpotifyConnect');
	return unless $prefs->client($client)->get('enableConnect');
	
	my $clientId = $client->id;
	
	# Don't start if already running
	if ($connectProcesses{$clientId} && $connectProcesses{$clientId}->{pid}) {
		if (kill 0, $connectProcesses{$clientId}->{pid}) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Spotify Connect already running for " . $client->name());
			return;
		}
	}
	
	my $account = Plugins::Spotty::AccountHelper->getAccount($client);
	return unless $account;
	
	my ($helper, $helperVersion) = Plugins::Spotty::Helper->get();
	return unless $helper;
	
	my $cacheDir = Plugins::Spotty::AccountHelper->cacheFolder($account);
	my $name = $prefs->client($client)->get('connectName') || $client->name() || 'Squeezebox';
	
	# Build command - run in discovery mode, output to stdout
	my @cmd = (
		$helper,
		'-n', $name,
		'-c', $cacheDir,
		'--backend', 'pipe',
		'--device-type', 'speaker',
	);
	
	# Add bitrate if supported
	if (Slim::Utils::Versions->checkVersion($helperVersion, '0.8.0', 10)) {
		push @cmd, '--bitrate', $prefs->get('bitrate') || 320;
	}
	
	# Add volume normalization if enabled
	if (Plugins::Spotty::Helper->getCapability('volume-normalisation') && $prefs->client($client)->get('replaygain')) {
		push @cmd, '--enable-volume-normalisation';
	}
	
	# Add fallback AP port if configured
	if ($prefs->get('forceFallbackAP') && !Plugins::Spotty::Helper->getCapability('no-ap-port')) {
		push @cmd, '--ap-port=12321';
	}
	
	# IMPORTANT: Do NOT add --disable-discovery - we want discovery enabled!
	
	# Add verbose logging if debug enabled
	if (main::DEBUGLOG && $log->is_debug) {
		push @cmd, '--verbose';
	}
	
	my $cmdString = join(' ', map { /\s/ ? qq{"$_"} : $_ } @cmd);
	main::INFOLOG && $log->is_info && $log->info("Starting Spotify Connect for " . $client->name() . ": $cmdString");
	
	# Fork and exec the process
	my $pid = fork();
	
	if (!defined $pid) {
		$log->error("Failed to fork Spotify Connect process: $!");
		return;
	}
	
	if ($pid == 0) {
		# Child process
		# Redirect stdout/stderr to /dev/null or log file
		if (!main::DEBUGLOG || !$log->is_debug) {
			open(STDOUT, '>', '/dev/null');
			open(STDERR, '>', '/dev/null');
		}
		
		# Execute spotty
		exec(@cmd) or exit(1);
	}
	
	# Parent process
	$connectProcesses{$clientId} = {
		pid => $pid,
		started => time(),
		client => $client,
	};
	
	main::INFOLOG && $log->is_info && $log->info("Spotify Connect started for " . $client->name() . " (PID: $pid)");
}

sub stopConnect {
	my ($class, $client) = @_;
	
	return unless $client;
	
	my $clientId = $client->id;
	my $processInfo = $connectProcesses{$clientId};
	
	return unless $processInfo && $processInfo->{pid};
	
	my $pid = $processInfo->{pid};
	
	main::INFOLOG && $log->is_info && $log->info("Stopping Spotify Connect for " . $client->name() . " (PID: $pid)");
	
	# Try graceful shutdown first
	if (kill 'TERM', $pid) {
		# Wait a bit for process to exit
		for (my $i = 0; $i < 10; $i++) {
			my $result = waitpid($pid, WNOHANG);
			last if $result == $pid || $result == -1;
			select(undef, undef, undef, 0.1);
		}
		
		# Force kill if still running
		if (kill 0, $pid) {
			kill 'KILL', $pid;
			waitpid($pid, 0);
		}
	}
	
	delete $connectProcesses{$clientId};
}

sub monitorProcesses {
	my $class = shift;
	
	# Check if Connect is globally enabled
	my $enabled = $prefs->get('enableSpotifyConnect');
	
	if ($enabled) {
		# Start Connect for all clients that have it enabled
		for my $client (Slim::Player::Client::clients()) {
			next unless $prefs->client($client)->get('enableConnect');
			
			my $clientId = $client->id;
			my $processInfo = $connectProcesses{$clientId};
			
			# Check if process is running
			if ($processInfo && $processInfo->{pid}) {
				my $pid = $processInfo->{pid};
				my $result = waitpid($pid, WNOHANG);
				
				if ($result == $pid || $result == -1 || !kill(0, $pid)) {
					# Process died
					$log->warn("Spotify Connect process died for " . $client->name() . ", restarting...");
					delete $connectProcesses{$clientId};
					
					# Restart after delay
					Slim::Utils::Timers::setTimer($class, time() + RESTART_DELAY, sub {
						$class->startConnect($client);
					});
				}
			} else {
				# Not running, start it
				$class->startConnect($client);
			}
		}
	} else {
		# Connect disabled globally, stop all processes
		foreach my $clientId (keys %connectProcesses) {
			if (my $processInfo = $connectProcesses{$clientId}) {
				$class->stopConnect($processInfo->{client});
			}
		}
	}
	
	# Schedule next check
	Slim::Utils::Timers::setTimer($class, time() + MONITOR_INTERVAL, \&monitorProcesses);
}

sub isRunning {
	my ($class, $client) = @_;
	
	return 0 unless $client;
	
	my $clientId = $client->id;
	my $processInfo = $connectProcesses{$clientId};
	
	return 0 unless $processInfo && $processInfo->{pid};
	
	return kill 0, $processInfo->{pid};
}

1;
