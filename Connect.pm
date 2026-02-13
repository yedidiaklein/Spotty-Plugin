package Plugins::Spotty::Connect;

use strict;

use File::Spec::Functions qw(catdir catfile);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::Spotty::AccountHelper;
use Plugins::Spotty::Helper;

# Platform-specific imports
BEGIN {
	if (!main::ISWINDOWS) {
		require POSIX;
		POSIX->import(qw(:sys_wait_h));
	}
}

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
	
	# Sanitize the device name - only allow alphanumeric, spaces, hyphens
	$name =~ s/[^\w\s\-]//g;     # Remove special chars except space and hyphen
	$name =~ s/\s+/ /g;           # Collapse multiple spaces
	$name =~ s/^\s+|\s+$//g;      # Trim leading/trailing spaces
	$name ||= 'Squeezebox';       # Fallback if name becomes empty
	
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
	
	# IMPORTANT: Do NOT add --disable-discovery - we want discovery enabled for Connect!
	
	# Add verbose logging if debug enabled
	if (main::DEBUGLOG && $log->is_debug) {
		push @cmd, '--verbose';
	}
	
	my $cmdString = join(' ', map { /\s/ ? qq{"$_"} : $_ } @cmd);
	main::INFOLOG && $log->is_info && $log->info("Starting Spotify Connect for " . $client->name() . ": $cmdString");
	
	my $pid;
	
	if (main::ISWINDOWS) {
		# On Windows, use system with START to run in background
		my $quotedCmd = join(' ', map { 
			my $arg = $_;
			$arg =~ s/"/\\"/g;  # Escape quotes
			/\s/ ? qq{"$arg"} : $arg 
		} @cmd);
		
		# Use START /B to run in background without creating a new window
		# Use a descriptive title to avoid issues with empty quotes
		system(qq{START /B "Spotty Connect - $name" $quotedCmd >NUL 2>&1});
		
		# Wait for process to start and find the most recent spotty.exe
		sleep 1;
		
		# Get all spotty.exe processes and find the newest one
		# This is a heuristic - not perfect but better than nothing
		my $output = `wmic process where "name='spotty.exe'" get processid,creationdate 2>NUL`;
		my @pids;
		while ($output =~ /(\d{14})\.\d+\+\d+\s+(\d+)/g) {
			my ($date, $foundPid) = ($1, $2);
			push @pids, { pid => $foundPid, date => $date };
		}
		
		if (@pids) {
			# Sort by creation date (newest first) and take the first one
			@pids = sort { $b->{date} cmp $a->{date} } @pids;
			$pid = $pids[0]->{pid};
		}
		
		if (!$pid) {
			$log->error("Failed to start Spotify Connect on Windows");
			return;
		}
	}
	else {
		# On Unix, fork and exec the process
		$pid = fork();
		
		if (!defined $pid) {
			$log->error("Failed to fork Spotify Connect process: $!");
			return;
		}
		
		if ($pid == 0) {
			# Child process
			# Redirect stdout/stderr to /dev/null unless debugging
			if (!main::DEBUGLOG || !$log->is_debug) {
				open(STDOUT, '>', '/dev/null');
				open(STDERR, '>', '/dev/null');
			}
			
			# Execute spotty
			exec(@cmd) or exit(1);
		}
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
	
	if (main::ISWINDOWS) {
		# On Windows, use taskkill
		system(qq{taskkill /PID $pid /F >NUL 2>&1});
	}
	else {
		# Try graceful shutdown first on Unix
		if (kill 'TERM', $pid) {
			# Wait a bit for process to exit
			for (my $i = 0; $i < 10; $i++) {
				my $result = POSIX::waitpid($pid, POSIX::WNOHANG);
				last if $result == $pid || $result == -1;
				select(undef, undef, undef, 0.1);
			}
			
			# Force kill if still running
			if (kill 0, $pid) {
				kill 'KILL', $pid;
				POSIX::waitpid($pid, 0);
			}
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
				my $running = 0;
				
				if (main::ISWINDOWS) {
					# On Windows, check if process exists
					$running = $class->_isWindowsProcessRunning($pid);
				}
				else {
					# On Unix, use waitpid with WNOHANG
					my $result = POSIX::waitpid($pid, POSIX::WNOHANG);
					$running = ($result == 0 && kill(0, $pid));
				}
				
				if (!$running) {
					# Process died
					$log->warn("Spotify Connect process died for " . $client->name() . ", restarting...");
					delete $connectProcesses{$clientId};
					
					# Restart after delay - check if client is still valid
					Slim::Utils::Timers::setTimer($class, time() + RESTART_DELAY, sub {
						# Verify the client object is still valid before restarting
						if ($client && ref $client && $client->can('id')) {
							$class->startConnect($client);
						}
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
	
	my $pid = $processInfo->{pid};
	
	if (main::ISWINDOWS) {
		# On Windows, verify the process still exists
		return $class->_isWindowsProcessRunning($pid);
	}
	else {
		return kill 0, $pid;
	}
}

# Helper function to check if a Windows process exists
sub _isWindowsProcessRunning {
	my ($class, $pid) = @_;
	
	return 0 unless $pid;
	
	# Use wmic to verify the process exists and is a spotty.exe
	my $output = `wmic process where "processid=$pid and name='spotty.exe'" get name 2>NUL`;
	return ($output =~ /spotty\.exe/i) ? 1 : 0;
}

1;
