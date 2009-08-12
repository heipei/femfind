#!/usr/bin/perl

require 5.0004;
use strict;
use DBI;
use Net::FTP;
use POSIX qw(locale_h tmpnam);
use Fcntl;
use locale;
use FemFind::ConfigReader qw(config_default config_read config_check config_error);
use FemFind::Helper qw(get_ip shell_escape);

my (%c, %symlinks) = ();
my $DB_CRAWLER_PASSWORD = 'crawler';
my $db = undef;
my ($HID, $SID, $PID);
my @cl = ('-c', '--complete', '-i', '--incremental', '-m', '--modify', '-t', '--tables');

INIT
{
}

END
{
	log_error("END: cleaning up...", 2);
	
	if (defined $c{TEMPFILE})
	{
		unlink($c{TEMPFILE}) or die "Couldn't unlink $c{TEMPFILE} : $!"
	}
	
	if (defined $db)
	{
		$db->disconnect;
	}
	unlock_process() if ($c{locked} == 1);
	close LOG;
}


init();
if (lock_process() == 1)
{
	$c{locked} = 1;
	apply_mod($c{DB_MODFILE_PATH} . '/femfind.mod');

	if ($c{DISABLE_SMB} ne 'yes')
	{
	    smb_crawl($c{CONTEXT});
	}
	
	if ($c{DISABLE_FTP} ne 'yes')
	{
	    ftps_to_database($c{FTPFILE});
	    ftp_crawl($c{CONTEXT});
	}
	smb_lookup();
	
	update_status();
}


##
## SUBS
##

sub init
{
	%c = config_default();
	
	if (@ARGV != 1)
	{
		help();
		exit 1;
	}
	
	
	%c = config_read(1);
	if (config_check() != 0)
	{
	    config_error();
		exit 1;
	}

	do
	{
		$c{TEMPFILE} = tmpnam();
	}
	until sysopen(FH, $c{TEMPFILE}, O_RDWR|O_CREAT|O_EXCL);
	
	sysopen(LOG, "$c{LOGFILE_PATH}/femfind.log", O_WRONLY|O_CREAT|O_APPEND) || print "Error: could not create logfile (femfind.log)\n";
	my $tmp = select(LOG);$| = 1;select($tmp);
	log_error(timestamp(\@ARGV), -1);
	$db = DBI->connect($c{DB}, $c{DB_CRAWLER_LOGIN}, $DB_CRAWLER_PASSWORD) ||
		(log_error("init: could not connect to database, reason: $DBI::errstring", 0)
		 && exit 1);

	my $arg = $ARGV[0];
	if ($arg eq $cl[0] || $arg eq $cl[1])
	{
		$c{CONTEXT} = $c{CRAWL_MAIN};
	}
	elsif ($arg eq $cl[2] || $arg eq $cl[3])
	{
		$c{CONTEXT} = $c{CRAWL_HOUR};
	}
	elsif ($arg eq $cl[4] || $arg eq $cl[5])
	{
		modedit();
		exit 0;
	}
	elsif ($arg eq $cl[6] || $arg eq $cl[7])
	{
		create_tables() ||
		  (log_error("FATAL: could not create tables, reason: $db->errstring", 0)
		   && die $c{ERR_FATAL});
		exit 0;
	}
	else
	{
		help();
		exit 1;
	}
	
	log_error("Context: $c{CONTEXT}", 0);
}

sub lock_process
{
	log_error("lock_process", 2);
	
	if (open(IN, "<$c{LOCKFILE_PATH}/femfind.lock"))
	{
		log_error("lock_process: lockfile from a previous instance exists, checking if process is still running", 0);
		my $pid = <IN>;
		chomp $pid;
		my @out = `ps -p $pid`;
		while (@out > 0 && ($_ = shift @out))
		{
			if (/\s*\Q$pid\E.*?crawler.pl/)
			{
				log_error("lock_process: previous instance still running. you might want to adjust your crontab settings. exit...\n", 1);
				return 0;
			}
		}
		log_error("lock_process: process not running anymore - database might be inconsistent! continuing..." , 0);
		close IN;
	}
	open(OUT, ">$c{LOCKFILE_PATH}/femfind.lock")
	    || (log_error("lock_process: could not create lock file!", 0)
	        && return 0);
	print OUT $$;
	close OUT;
	
	return 1;
}

sub modedit
{
	my $mf = $c{DB_MODFILE_PATH} . "/femfind.mod";
	print "Edit database modification file\n\nReading current modfile ($mf)\n";
	my @mods = modfile_load($mf);
	my $lines = @mods;
	print "$lines lines read.\n";
	
	while (1)
	{
		print "\n1 - Change PreferedTime for SMB Host\n",
		      "2 - Change PreferedTime for FTP Host\n",
		      "3 - Exclude SMB host from scanning\n",
		      "9 - Save and quit\nYour choice: ";
		my $in = <STDIN>;
		chop $in;
		my $out = '';
		if ($in eq '1')
		{
			$out = modfile_time($c{SMB});
		}
		elsif ($in eq '2')
		{
			$out = modfile_time($c{FTP});
		}
		elsif ($in eq '3')
		{
			$out = modfile_time($c{SMB}, 9000);
		}
		elsif ($in eq '9')
		{
			modfile_save($mf, \@mods);
			exit 0;
		}
		if ($out ne '')
		{
			if (!modfile_dupecheck($out, \@mods))
			{
				push @mods, $out;
				print "Added.\n";
			}
			else
			{
				print "Duplicate entry - ignoring...\n";
			}
		}
	}
}

sub modfile_time
{
	my ($type, $time) = @_;
	
	print "Host: ";
	my $name = uc <STDIN>;chomp $name;
	my $hour, my $min;
	if (!defined $time)
	{
		do
		{
			print "PreferedTime hour (0..23): ";
			$hour = <STDIN>;chomp $hour;
			$hour = int($hour);
		} while ($hour > 23 || $hour < 0);
		do
		{
			print "PreferedTime minute(0..59): ";
			$min = <STDIN>;chomp $min;
			$min = int($min);
		} while ($min > 59 || $min < 0);
		$time = $min + $hour*100;
	}
	my $string = join('~~~', quote($name), $type, $time);
	
	return $string;
}

sub modfile_load
{
	my ($file) = @_;
	my @contents = ();
	
	open (IN, "<$file") || print "Could not open modfile!\n";
	while (<IN>)
	{
		next if ($_ =~ m/^#/);
		chomp;
		push @contents, $_;	
	}
	
	close IN;
	
	return @contents;
}

sub modfile_save
{
	my ($file, $mods) = @_;
	
	open (OUT, ">$file");
	while ($_ = shift @$mods)
	{
		print OUT "$_\n";
	}
	
	close OUT;
}

sub modfile_dupecheck                                                                                                                      
{                                                                                                                                   
	my ($string, $contents) = @_;
	
	my $ind = 0;
	my $found = 0;
	while ($ind < @$contents && $found == 0)                                                                                     
	{
		$found = 1 if ($contents->[$ind] eq $string);
		$ind++;
	}
	return $found;
}
sub unlock_process
{
	log_error("unlock_process", 2);
	unlink("$c{LOCKFILE_PATH}/femfind.lock");
}

sub help
{
    print <<END
Wrong number of argument(s) or invalid operation.
Please check the README for a thorough explanation of features.

FemFind Crawler v$c{VERSION}. For latest, check http://femfind.codefactory.de/
Usage: crawler.pl operation
where operation is
    $cl[0], $cl[1]	complete crawl
    $cl[2], $cl[3]	subsequent crawl
    $cl[4], $cl[5]	change the database mod. file (see README)
    $cl[6], $cl[7]	create table structure (old data will be lost!)
END
}

sub ftps_to_database
{
	log_error("ftps_to_database", 2);
	(my $path) = @_;
	
	exec_sql("DELETE FROM FTP", 1);
	
	open (IN, "<$path/ftp_list") || log_error("could not open ftp_list", 1);
	while ($_ = <IN>)
	{
		next if (/^#/);
		chomp;
		my @parts = split(/#__/, $_);
		next if (@parts < 4);
		$parts[4] = '' if (!defined $parts[4]);
		exec_sql('INSERT INTO FTP values (' . quote($parts[0]) . ',' . quote($parts[1]) . ',' .
		quote($parts[2]) . ',' . quote($parts[3]) . ',' . quote($parts[4]) . ')', 1);
	}
	close IN;
}

sub smb_lookup
{
	log_error("smb_lookup", 2);
	
	my %smb_hosts = ();
	my $cmd = $db->prepare("SELECT HostName, WorkGroup from Host");
	$cmd->execute();
	
	while ((my @row = $cmd->fetchrow_array()))
	{
		if (defined(my $ip = get_ip($row[0], $row[1], $c{SMB_PATH},
									$c{SMB_ACCPARAM}, 0)))
		{
			$smb_hosts{$row[0]} = $ip;
		}
	}
	
	$db->do("LOCK TABLES SMBtoIP WRITE");
	$db->do("DELETE FROM SMBtoIP");
	foreach (keys %smb_hosts)
	{
		$db->do('INSERT INTO SMBtoIP VALUES (' . quote($_) . ',' . quote($smb_hosts{$_}) . ')');
	}
	$db->do("UNLOCK TABLES");
}

sub apply_mod
{
	(my $file) = @_;
	
	log_error("apply_mod: $file", 2);
	open (IN, "<$file") || log_error("apply_mod: could not find $file", 1);
	while (my $line = <IN>)
	{		
		chomp $line;
		my ($host, $type, $time) = split('~~~', $line);
		if ($db->selectrow_array("SELECT count(*) from Host where HostName=$host AND HostType=$type") != 0)
		{
			exec_sql("UPDATE Host set PreferedTime=$time where HostName=$host AND HostType=$type", 1);
		}
		else
		{
			exec_sql("INSERT INTO Host values (NULL, $host, '', $type, NOW(), 0, $time)", 1);
		}
	}
	close IN;
}

sub update_status
{
	log_error("update_status", 2);
	
	(my $files, my $filesize) = $db->selectrow_array("SELECT count(*), sum(FileSize) FROM File");
	
	if (!defined $files)
	{
		log_error("update_status: File.ISM probably inconsistent", 0);
		return;
	}
	
	my $smbhosts = $db->selectrow_array("SELECT COUNT(*) FROM Host WHERE HostType=$c{SMB}");
	my $ftphosts = $db->selectrow_array("SELECT COUNT(*) FROM Host WHERE HostType=$c{FTP}");
#	my $max_dateadded = $db->selectrow_array("SELECT max(DateAdded) from File");
	(my $sec, my $min, my $hour, my $day, my $month, my $year) = localtime time;
	$month++;
	$year += 1900;
	$min = (length $min == 1) ? " $min" : $min;
	my $lastchange = sprintf "%02d. %02d. %4d %02d:%02d", $day, $month, $year, $hour, $min;
	my $out = "";
	$filesize = int ($filesize / (1024*1024*1024));
	while ($filesize =~ s/(...)$//g)
	{
		$out = '.'.$1.$out;
	}
	$out = $filesize.$out;
	$out =~ s/^\.//;
	$out .= " GB";
	exec_sql('DELETE FROM Status', 1);
	exec_sql("INSERT INTO Status VALUES ($files, " . quote($out) . ", $smbhosts, $ftphosts," . quote($lastchange) . ')', 1);
}

sub smb_crawl
{
	log_error("smb_crawl", 2);
	
	my ($cCONTEXT) = @_;
	
	my %hosts_online = get_smb_host_list($c{SMB_MASTERBROWSER}, $c{SMB_MB_WORKGROUP});
	my %hosts_exclude = my %hosts_crawl = my %hosts_new = ();
	my %host_count = ();
	
	my $include_select, my $exclude_select;
	
	if ($cCONTEXT == $c{CRAWL_MAIN})
	{
		$include_select = "SELECT HostName, WorkGroup from Host WHERE PreferedTime=-1 AND HostType=$c{SMB}";
		$exclude_select = "SELECT HostName from Host WHERE PreferedTime>-1 AND HostType=$c{SMB}";
	}
	elsif ($cCONTEXT == $c{CRAWL_HOUR})
	{
		$include_select = "SELECT HostName, WorkGroup from Host WHERE ((PreferedTime > $c{TIME_MIN} AND PreferedTime < $c{TIME_MAX}) OR ExpireCount > 0) AND HostType=$c{SMB}";
		$exclude_select = "SELECT HostName from Host WHERE HostType=$c{SMB}";
	}
	
	my $cmd = $db->prepare($include_select);
	$cmd->execute();
	while (my @row = $cmd->fetchrow_array)
	{
		$hosts_crawl{$row[0]} = $row[1];
	}
	my $t_exclude = $db->selectcol_arrayref($exclude_select);
	foreach ( @$t_exclude ) 
	{
		$hosts_exclude{$_} = 1; 
	}
	
	foreach (keys %hosts_online)
	{
		if (!defined $hosts_crawl{$_} && !defined $hosts_exclude{$_})
		{
			$hosts_crawl{$_} = $hosts_online{$_};
			$hosts_new{$_} = 1;
		}
	}	
	
	
	# now crawl all hosts
	foreach my $host (sort keys %hosts_crawl)
	{
		my %share_count = ();
		my $new_host = defined $hosts_new{$host};
		
		my $ht = shell_escape($host);
		my $wt = shell_escape($hosts_crawl{$host});

		my @out = `$c{SMB_PATH}/smbclient \"//$ht/\" $c{SMB_ACCPARAM} -L \"$ht\" -W \"$wt\"`;
		if ($? != 0)
		{
		    log_error("smb_crawl: Fatal: could not retrieve share listing from $host. Probably wrong login/password.", 1);
		    next;
		}
		
		shift @out while ($out[0] !~ m/^\tSharename/ && @out > 0);
		shift @out;shift @out;
		
		while (@out > 0 && $out[0] ne '')
		{
			$_ = shift @out;
			m/^\t(.{15})\s*Disk/;
			my $share = $1;
			$share =~ s/^\s+//;
			$share =~ s/\s+$//;
			next if ($share eq '' || $share =~ m/IPC\$/);
			next if ($share =~ /\$$/ && $c{CRAWL_HIDDEN} eq 'no');
			log_error("smb_crawl: found share $share on host $host", 2);
#			if ($host_count{$host} != 2)
#			{
#			    $host_count{$host} = 1;
#  			}
			if (smb_crawl_share($host, $hosts_crawl{$host}, $share, $new_host) > 0)
			{
				$share_count{$share}--;
				$host_count{$host} = 1;
			}		
		}	        
		my $out = $db->selectcol_arrayref("SELECT ShareName FROM Host NATURAL LEFT JOIN Share WHERE HostName="
		. quote($host) . " AND HostType=$c{SMB}");
		foreach (@$out) 
		{
			$share_count{$_}++;
		}
		
		my @purge_shares = ();    	
		foreach (keys %share_count)
		{
			push @purge_shares, $_ if ($share_count{$_} == 1)
		}
		purge_shares ($host, $c{SMB}, \@purge_shares) if (@purge_shares > 0);
		
		if ($host_count{$host} == 1)
		{
			log_error("smb_crawl: refreshing $host", 2);
			exec_sql('UPDATE Host SET LastScan=NOW(), ExpireCount=0 WHERE HostName=' . quote($host) . " AND HostType=$c{SMB}", 1);
		}
		else
		{
			# no shares for this host, so let´s delete it
			log_error("smb_crawl: purge_hosts $host", 2);
			my @tmp = ($host);
			purge_hosts(\@tmp, $c{SMB});
		}
	}
	
	my @expire_hosts = ();
	foreach (keys %hosts_crawl)
	{
		push @expire_hosts, $_ if (!defined $host_count{$_} && !defined $hosts_new{$_});
	}
	expire_hosts(\@expire_hosts, $c{SMB});
	
	my $purge_hosts = $db->selectcol_arrayref("SELECT HostName FROM Host WHERE ExpireCount>$c{SMB_EXPIRE} AND HostType=$c{SMB}");
	purge_hosts($purge_hosts, $c{SMB});
}

# returns true if files were found
sub smb_crawl_share
{
	my ($host, $workgroup, $share, $new_host) = @_;
	my %path_count = my %datetime = my %filesize = ();

	my ($numfiles, $PID) = 0;	
	
	log_error("smb_crawl_share: $workgroup//$host/$share", 2);
	
	my $ht = shell_escape($host);
	my $st = shell_escape($share);
	my $wt = shell_escape($workgroup);

	`$c{SMB_PATH}/smbclient \"//$ht/$st\" $c{SMB_ACCPARAM} -c 'recurse;ls' -d0 -D . -W \"$wt\" >$c{TEMPFILE}`;
	if ($? != 0)
	{
		log_error("smb_crawl_share: Fatal: Problem while trying to browse //$host/$share", 1);
		return undef;
	}
	
	open (IN, "<$c{TEMPFILE}");
	$_ = <IN>;
	my $root = "";
	my $next_root = "";
	while ( !eof(IN) )
	{
		my $nextdir = 0;
		my @files = ();
		do
		{
			$_ = <IN>;
			if (m/^\\/g)
			{
				$nextdir = 1;
				$next_root = $_;
			}
			elsif (m/^  /)
			{
				chomp;
				my $fattrib = substr $_, -42, 7;
				if ($fattrib !~ m/D/)
				{
					# extract info from string
					my $fyear = substr $_, -4, 4;
					my $fsize = substr $_, -35, 9;
					my $ftime = substr $_, -13, 8;
					my $fmonth = substr $_, -20, 3;
					my $fday = substr $_, -16, 2;
					my $filename = substr $_, 2, length ($_) - 42;
					$filename =~ s/\s+$//go;
					$fday =~ s/^\s+//go;
					$fsize =~ s/^\s+//go;
					$fsize =~ s/^[0 ]+//g;
					$fsize = 0 if ($fsize eq '');
					# write data to hash for insertion into database
					my $tmpday = (length $fday == 2) ? $fday : "0".$fday;
					$datetime{$filename} = "$fyear-$c{MONTHS}{$fmonth}-$tmpday $ftime";
					$filesize{$filename} = $fsize;
					if ((defined $c{MONTHS}{$fmonth}) && $filename ne '')
					{
						push @files, $filename;	
						$numfiles++;
					}
				}
			}
		}
		while ($nextdir != 1 && !eof(IN));
		$path_count{$root}-- if ($#files >= 0);
				
		if ($new_host == 1)
		{
			#insert ´em all
			add_files_new_host($host, $workgroup, $c{SMB}, "", "", 0, $share, $root, \@files, \%filesize, \%datetime) if (@files > 0);
		}
		elsif (create_path_structure($host, $c{SMB}, $share, $root, \@files) && defined $c{PID})
		{
			my $oldfiles = $db->selectcol_arrayref("SELECT FileName from File WHERE PID=$c{PID}");
			my @remove = my @insert = ();
			my %file_count = my %touch = ();
			
			# compute index-oldfiles and oldfiles-index
			# -1 file must be removed
			#  0 file must stay in database
			#  1 new file, add to database				
			foreach (@$oldfiles) 
			{
				$file_count{$_}--;
			}
			foreach (@files)
			{
				$file_count{$_}++;
			}
			foreach my $key (keys %file_count)
			{
				if ($file_count{$key} == 0)
				{
					$touch{$key} = 1;
				}
				elsif ($file_count{$key} == 1)
				{
					push @insert, $key;
				}
				else
				{
					push @remove, $key;
				}
			}
			touch_files($c{PID}, \%touch, \%datetime);
			add_files($c{PID}, \@insert, \%filesize, \%datetime) if (@insert > 0);
			purge_files($c{HID}, $c{SID}, $c{PID}, \@remove) if (@remove > 0);
		}
		
#	while (!eof(IN) && ($_ !~ m/^(\\.*)/))
#	{
#	        $_ = <IN>;
#	}
		if ( !eof(IN) )
		{
			$root = $next_root;
			chomp $root;
			$root =~ s/\\/\//g;
		}
	}
	my @purge_path = ();
	my $out = $db->selectcol_arrayref("SELECT PathName FROM Path NATURAL LEFT JOIN Share NATURAL LEFT JOIN Host ".
	"WHERE HostName=" . quote($host) . " AND HostType=$c{SMB} AND ShareName=" .
	quote($share));
	#syntax changed
	foreach (@$out) 
	{
		$path_count{$_}++;
	}
	
	foreach (keys %path_count)
	{
		push (@purge_path, $_) if ($path_count{$_} == 1);
	}
	purge_paths($host, $c{SMB}, $share, \@purge_path) if (@purge_path > 0);
	
	close IN;	
	
	log_error("smb_crawl_share: found $numfiles files", 2);
	return $numfiles;
}

sub get_smb_host_list
{
	log_error("get_smb_host_list", 2);
	
	(my $masterbrowser, my $workgroup_mb) = @_;
	my (%hostlist, %workgroups) = ();
	
	#if (system("$c{SMB_PATH}/smbclient -h >/dev/null") != 1)
	#{
	#	log_error("get_smb_host_list: fatal: could not find SMB services (time=$c{DATE})", 0);
	#	die "smbclient not available"
	#}
	
	log_error("get_smb_host_list: Retrieving Workgroup Info...", 2);
	my $mt = shell_escape($masterbrowser);
	my $wt = shell_escape($workgroup_mb);
	my @out = `$c{SMB_PATH}/smbclient \"//$mt/\" $c{SMB_ACCPARAM} -L \"$mt\" -W \"$wt\"`;
	shift @out while ($out[0] !~ /Workgroup/ && @out > 0);
	shift @out;shift @out;
	
	foreach (@out)
	{
		chomp;

		my $wgroup = substr $_, 1, 16;
		my $master = "fileserver";	#substr $_, 21;
		$wgroup =~ s/\s+$//;
		$master =~ s/^\s+//;
		
		next if ($wgroup eq '' || $master eq '');

		$workgroups{$wgroup} = $master;
		log_error("get_smb_host_list: found workgroup $wgroup [masterbrowser: $master]", 2);
	}
	
	log_error("get_smb_host_list: Retrieving Hosts Infos...", 2);
	
	foreach my $wg (keys %workgroups)
	{
		log_error("get_smb_host_list: Contacting $workgroups{$wg}", 2);
		my $mb = shell_escape($workgroups{$wg});
		my $wt = shell_escape($wg);	
		@out = `$c{SMB_PATH}/smbclient \"//$mb/\" $c{SMB_ACCPARAM} -L \"$mb\" -W \"$wt\"`;
		shift @out while ($out[0] !~ m/\tServer/ && @out > 0);
		shift @out;shift @out;
		my $index = 0;
		$index++ while ($out[$index] !~ m/\tWorkgroup/ && $index <= $#out);
		next if ($index == $#out);
		$#out = $index - 2;
		
		foreach (@out)
		{
			my $host = uc(substr $_, 1, 16);
			$host =~ s/\s+$//;
			$hostlist{$host} = $wg;
			log_error("get_smb_host_list: found host $host in workgroup $wg", 2);
		}
	}
	return %hostlist;
}

sub ftp_crawl
{
	log_error("ftp_crawl", 2);
	
	my ($cCONTEXT) = @_;
	
	my %hosts_db = get_ftp_host_list();
	my %hosts_exclude = my %hosts_crawl = my %hosts_new = ();
	my %host_count = ();
	
	my ($exclude_select, $include_select);
	
	if ($cCONTEXT == $c{CRAWL_MAIN})
	{
		$exclude_select = "SELECT HostName from Host WHERE PreferedTime>-1 AND HostType=$c{FTP}";
		$include_select = "SELECT FTP.HostName, Login, PassWord, Port from Host NATURAL LEFT JOIN FTP WHERE PreferedTime=-1 AND Host.HostType=$c{FTP}"
	}
	elsif ($cCONTEXT == $c{CRAWL_HOUR})
	{
		$exclude_select = "SELECT HostName from Host WHERE HostType=$c{FTP}";
		$include_select = "SELECT FTP.HostName, Login, PassWord, Port from Host NATURAL LEFT JOIN FTP WHERE ((PreferedTime > $c{TIME_MIN} AND PreferedTime < $c{TIME_MAX}) OR ExpireCount > 0) AND Host.HostType=$c{FTP}";
	}
	
	my $cmd = $db->prepare($include_select);
	$cmd->execute();
	while (my @row = $cmd->fetchrow_array())
	{
		my @tmp = ($row[1], $row[2], $row[3]);
		$hosts_crawl{$row[0]} = \@tmp;
	}
	
	my $t_exclude = $db->selectcol_arrayref($exclude_select);
	foreach ( @$t_exclude )
	{
		$hosts_exclude{$_} = 1;
	}
	
	foreach (keys %hosts_db)
	{
		if (!defined $hosts_crawl{$_} && !defined $hosts_exclude{$_})
		{
			$hosts_crawl{$_} = $hosts_db{$_};
			$hosts_new{$_} = 1;
		}
	}		
	
	foreach my $host (sort keys %hosts_crawl)
	{
		my $ip = get_ip($host, '', $c{SMB_PATH}, $c{SMB_ACCPARAM}, 0);
		
		log_error("ftp_crawl: $host ($ip)", 2);
		my $new_host = defined $hosts_new{$host};
		next if (!ftp_available($ip));
		
		$host_count{$host} = 1;
		if (ftp_crawl_share($host, $ip, $hosts_crawl{$host}->[0], $hosts_crawl{$host}->[1], $hosts_crawl{$host}->[2], $hosts_new{$host}))
		{
			exec_sql('UPDATE Host SET LastScan=NOW(), ExpireCount=0 WHERE HostName=' . quote($host) . " AND HostType=$c{FTP}", 1);
		}
		else
		{
			# no shares for this host, so let´s delete it
			log_error("ftp_crawl: purge_hosts $host", 2);
			my @tmp = ($host);
			purge_hosts(\@tmp, $c{FTP});
		}
	}
	
	my @expire_hosts = ();
	foreach (keys %hosts_crawl)
	{
		push @expire_hosts, $_ if (!defined $host_count{$_} && !defined $hosts_new{$_});
	}
	expire_hosts(\@expire_hosts, $c{FTP});
	
	my $purge_hosts = $db->selectcol_arrayref("SELECT HostName FROM Host WHERE ExpireCount>$c{FTP_EXPIRE} AND HostType=$c{FTP}");
	purge_hosts($purge_hosts, $c{FTP});
}

sub ftp_crawl_share
{
	my ($host, $ip, $login, $password, $port, $new_host) = @_;
	log_error("ftp_crawl_share: $login:$password\@$host", 2);
	
	my $year = ((localtime time)[5]) + 1900;
	
	my %path_count = my %datetime = my %filesize = ();
	my $numfiles = 0;
	my @files = ();
	
	open (IN, ">$c{TEMPFILE}");
	my $fh = select(IN);$| = 1;select($fh);
	
	ftp_get_listing($ip, $login, $password, $port, *IN);
	close IN;
	
	open (IN, "<$c{TEMPFILE}");
	
	my $root_new = <IN>;
	while (!eof(IN))
	{
		my $root = $root_new;
		$root =~ s/\\/\//g;
		$root =~ s/\/$//;
		
		my $nextdir = 0;
		@files = ();
		do
		{
			$_ = <IN>;
			if (!m/^\t/g)
			{
				$root_new = $_;
				chomp $root_new;
				$nextdir = 1;
			}
			else
			{
				chomp;
				# extract info from string
				m/^\t\S+\s+\S+\s+\S+\s+\S+\s+(\S+)\s+(\S+)\s+(\d+)\s+(\S+) (.*)$/;
				my $filename = $5;
				my $fsize = $1;
				my $ftime = $4;
				my $fyear;
				my $fmonth = $2;
				my $fday = $3;
				if ($ftime =~ m/:/)
				{
					$fyear = $year;
					$ftime .= ':00';
				}
				else
				{
					$fyear =  $ftime;
					$fyear =~ s/^\s+//;
					$ftime = '00:00:00';
				}
				
				$fyear =~ s/^\s+//go;
				$fday =~ s/^\s+//go;
				$fsize =~ s/^\s+//go;
				$fsize =~ s/^0+//g;
				$fsize = 0 if ($fsize eq '');
				# write data to hash for insertion into database
				my $tmpday = (length $fday == 2) ? $fday : "0".$fday;
				$datetime{$filename} = "$fyear-$c{MONTHS}{$fmonth}-$tmpday $ftime";
				$filesize{$filename} = $fsize;
				
				push @files, $filename;	
				$numfiles++;
			}
		}
		while ($nextdir != 1 && !eof(IN));
		$path_count{$root}-- if ($#files >= 0);
		
		if ($new_host == 1)
		{
			#insert ´em all
			add_files_new_host($host, "", $c{FTP}, $login, $password, $port, "", $root, \@files, \%filesize, \%datetime) if (@files > 0);
		}
		elsif (create_path_structure($host, $c{FTP}, "", $root, \@files) && defined $c{PID})
		{
			my $oldfiles = $db->selectcol_arrayref("SELECT FileName from File WHERE PID=$c{PID}");
			my @remove = my @insert = ();
			my %file_count = my %touch = ();
			
			# compute index-oldfiles and oldfiles-index
			# -1 file must be removed
			#  0 file must stay in database
			#  1 new file, add to database				
			foreach (@$oldfiles) 
			{
				$file_count{$_}--;
			}
			foreach (@files)
			{
				$file_count{$_}++;
			}
			foreach my $key (keys %file_count)
			{
				if ($file_count{$key} == 0)
				{
					$touch{$key} = 1;
				}
				elsif ($file_count{$key} == 1)
				{
					push @insert, $key;
				}
				else
				{
					push @remove, $key;
				}
			}
			
			touch_files($c{PID}, \%touch, \%datetime);
			add_files($c{PID}, \@insert, \%filesize, \%datetime) if (@insert > 0);
			purge_files($c{HID}, $c{SID}, $c{PID}, \@remove) if (@remove > 0);
		}
	}
	
	my @purge_path = ();
	my $out = $db->selectcol_arrayref("SELECT PathName FROM Path NATURAL LEFT JOIN Share NATURAL LEFT JOIN Host ".
	"WHERE HostName=" . quote($host) . " AND HostType=$c{FTP} AND ShareName=\"\"");
	
	foreach (@$out) 
	{
		$path_count{$_}++;
	}
	foreach (keys %path_count)
	{
		push (@purge_path, $_) if ($path_count{$_} == 1);
	}
	purge_paths($host, $c{FTP}, "", \@purge_path) if (@purge_path > 0);
	
	close IN;
	
	log_error("ftp_crawl_share: found $numfiles files", 2);
	return $numfiles > 0;
}

sub get_ftp_host_list
{
	log_error("get_ftp_host_list", 2);
	
	my %hostlist = ();
	my $cmd = $db->prepare("SELECT HostName, Login, PassWord, Port from FTP");
	$cmd->execute();
	while (my @out = $cmd->fetchrow_array())
	{
		my @tmp = ($out[1], $out[2], $out[3]);
		$hostlist{$out[0]} = \@tmp;
	}
	return %hostlist;
}

sub ftp_available
{
	(my $host) = @_;
	
	log_error("ftp_available: $host", 2);
	
	return undef if ($host eq '');
	return ((`ping -c 1 -i 1 $host` =~ m/time/) ? 1 : undef);
}

sub quote
{
	return $db->quote(@_[0]);
}

# returns PID
sub create_path_structure
{
	my ($host, $hosttype, $share, $path, $files) = @_;
	log_error("create_path_structure: $host/$share/$path", 2);
	
	my $HID = $db->selectrow_array("SELECT HID from Host WHERE HostName=" . quote($host) . " AND HostType=$hosttype");
	if (!defined $HID)
	{
		log_error("create_path_structure: error trying to get HID for $host", 0);
		return undef;
	}
	
	my $SID_select = "SELECT SID from Share WHERE ShareName=" . quote($share) . " AND HID=$HID";
	my $SID = $db->selectrow_array($SID_select);
	return undef if ($#$files < 0 && !defined $SID);
	if (!defined $SID)
	{
		log_error("create_path_structure: $hosttype, creating entry for share=$share", 2);
		exec_sql('INSERT INTO Share VALUES (NULL,' . quote($share) . ", $HID)", 1);
		$SID = $db->selectrow_array($SID_select);	
	}
	
	my $PID_select = "SELECT PID from Path WHERE HID=$HID AND SID=$SID AND PathName=" . quote($path);
	my $PID = $db->selectrow_array($PID_select);								
	return undef if ($#$files < 0 && !defined $PID);
	if (!defined $PID)
	{
		log_error("create_path_structure: $hosttype,  creating entry for path=$path", 2);
		exec_sql('INSERT INTO Path VALUES (NULL,' . quote($path) . ", $HID, $SID)", 1);
		$PID = $db->selectrow_array($PID_select);
	}
	
	if (!defined $PID)
	{
		return undef;
	}
	
	$c{SID} = $SID;
	$c{HID} = $HID;
	$c{PID} = $PID;
	
	return 1;
}

# host, path, share must be in table!!!
sub add_files
{
	(my $PID, my $files, my $filesize, my $datetime) = @_;
	
	log_error("add_files: PID=$PID [batchjob]", 2);
	exec_sql_insert_batch($PID, $files, $c{DATE}, $filesize, $datetime);
}

sub add_files_new_host
{
	my ($host, $workgroup, $hosttype, $login, $password, $port, $share, $path, $files, $filesize, $datetime) = @_;
	log_error("add_files_new_host: $host", 2);	
	
	# host may have already been defined by an earlier call
	my $HID_select = "SELECT HID from Host WHERE HostName=" . quote($host) . " AND HostType=$hosttype";
	my $HID = $db->selectrow_array($HID_select);
	if (!defined $HID)
	{
		log_error("add_files_new_host: creating entry for host=$host workgroup=$workgroup", 2);
		
		exec_sql('INSERT INTO Host VALUES (NULL,' . quote($host) . ',' . quote($workgroup) . ", $hosttype, NOW(), 0, -1)", 1);
		$HID = $db->selectrow_array($HID_select);
	}
	
	my $SID_select = "SELECT SID from Share WHERE ShareName=" . quote($share) . " AND HID=$HID";
	my $SID = $db->selectrow_array($SID_select);
	if (!defined $SID)
	{
		log_error("add_files_new_host: creating entry for share=$share", 2);
		exec_sql('INSERT INTO Share VALUES (NULL,' . quote($share) . ',' . quote($HID) . ')', 1);
		$SID = $db->selectrow_array($SID_select);
	}
	
	log_error("add_files_new_host: creating entry for path=$path", 2);
	exec_sql("INSERT INTO Path VALUES (NULL," . quote($path) . ", $HID, $SID)", 1);
	my $PID = $db->selectrow_array("SELECT PID from Path WHERE HID=$HID AND SID=$SID ".
	"AND PathName=" . quote($path));
	
	log_error("add_files_new_host: PID=$PID [batchjob]", 2);
	exec_sql_insert_batch($PID, $files, $c{DATE}, $filesize, $datetime);
}

sub touch_files
{
	(my $PID, my $touch, my $datetime) = @_;
	
	$PID = quote($PID);
	my $cmd = $db->prepare("SELECT FileName, FileDate FROM File WHERE PID=$PID");
	$cmd->execute();
	while (my @out = $cmd->fetchrow_array())
	{
		# touch changed files in database
		if ($touch->{$out[0]} == 1 && $out[1] ne $datetime->{$out[0]})
		{
			log_error("touch_files: fn_db: /$out[0]/ fd_db: /$out[1]/  fd_fs: /$datetime->{$out[0]}/", 2);
			exec_sql("UPDATE File SET DateAdded=$c{DATE}, FileDate=" . quote($datetime->{$out[0]}) .
			" WHERE FileName=" . quote($out[0]) . " AND PID=$PID", 1);
		}
	}
}

sub purge_files
{
	(my $HID, my $SID, my $PID, my $files) = @_;
	
	log_error("purge_files: deleting files [batchjob]", 2);
	
	# remove all the files from the specified host/share/path location
	exec_sql_delete_batch($PID, $files);
}

sub purge_paths
{
	(my $host, my $hosttype, my $share, my $pathnames) = @_;
	
	log_error("purge_paths: $host/$share", 2);
	
	my $HID = $db->selectrow_array("SELECT HID from Host WHERE HostName=" . quote($host) . " AND HostType=$hosttype");
	if (!defined $HID)
	{
		log_error("purge_paths: error trying to get HID for $host, $share", 1);
		return undef;
	}
	
	my $SID = $db->selectrow_array("SELECT SID FROM Share WHERE ShareName=" . quote($share) . " AND HID=$HID");
	if (!defined $SID)
	{
		log_error("purge_paths: error trying to get SID for $host, $share", 1);
		return undef;
	}
	
	foreach (@$pathnames)
	{
		log_error("purge_paths: purging $host/$share/$_", 2);
		my $PID = $db->selectrow_array("SELECT PID FROM Path WHERE PathName=" . quote($_) . " AND HID=$HID AND SID=$SID");
		exec_sql("DELETE FROM File WHERE PID=$PID", 1);
		exec_sql("DELETE FROM Path WHERE PID=$PID", 1);
	}
}

sub purge_shares
{
	(my $host, my $hosttype, my $sharenames) = @_;
	
	log_error("purge_shares: $host", 2);
	
	my $HID = $db->selectrow_array("SELECT HID from Host WHERE HostName=" . quote($host) . " AND HostType=$hosttype");
	if (!defined $HID)
	{
		log_error("purge_shares: error trying to get HID for $host", 1);
		return undef;
	}
	
	foreach (@$sharenames)
	{
		log_error("purge_shares: purging $host/$_", 2);
		my $SID = $db->selectrow_array("SELECT SID FROM Share WHERE ShareName=" . quote($_) . " AND HID=$HID");
		
		# maybe the share has already been deleted by purge_paths
		if (!defined $SID)
		{
			log_error("purge_shares: error trying to get SID for $host/$_", 1);
			next;
		}
		
		my $pathnames = $db->selectcol_arrayref("SELECT PathName FROM Path WHERE HID=$HID AND SID=$SID");
		purge_paths($host, $hosttype, $_, $pathnames);
		
		exec_sql("DELETE FROM Share WHERE SID=$SID", 1);
	}
}

sub purge_hosts
{
	my ($hosts, $hosttype) = @_;
	
	log_error("purge_hosts", 2);
	
	foreach (@$hosts)
	{
		log_error("purge_hosts: purging $_", 2);
		my $HID = $db->selectrow_array("SELECT HID from Host WHERE HostName=" . quote($_) . " AND HostType=$hosttype");
		if (!defined $HID)
		{
			log_error("purge_hosts: error trying to get HID for $_", 1);
			next;
		}
		exec_sql("DELETE FROM Share WHERE HID=$HID", 1);
		my $paths = $db->selectcol_arrayref("SELECT PID FROM Path WHERE HID=$HID");
		exec_sql("DELETE FROM Host WHERE HID=$HID", 1);
		next unless (@$paths > 0);
		foreach my $PID (@$paths)
		{
			exec_sql("DELETE FROM File WHERE PID=$PID")
		}
		exec_sql("DELETE FROM Path WHERE HID=$HID", 1);
	}
}

sub expire_hosts
{
	(my $hosts, my $hosttype) = @_;
	
	log_error("expire_hosts", 2);
	
	foreach (@$hosts)
	{
		log_error("expire_hosts: expiring $_", 2);
		my ($HID, $ExpireCount) = $db->selectrow_array("SELECT HID, ExpireCount from Host WHERE HostName=" . quote($_) .
		" AND HostType=$hosttype");
		if (!defined $HID)
		{
			log_error("expire_hosts: error trying to get HID for $_ (host wasn't in database)", 2);
			next;
		}
		$ExpireCount++;
		exec_sql("UPDATE Host SET ExpireCount=$ExpireCount WHERE HID=$HID", 1);
	}
}

sub exec_sql
{
	(my $sql, my $LOG) = @_;
	
	log_error("exec_sql", 2);
	
	my $cmd = $db->do($sql)
	    || log_error("exec_sql: error while executing $sql", 0);
	if ($LOG == 1)
	{
		if ($sql =~ m/NULL/i)
		{
			#my $id = bless $cmd->{mysql_insertid};
			#$sql =~ s/NULL/$id/i;
		}
		log_error("[SQL] $sql", 3);
	}
}

sub exec_sql_insert_batch
{
	my ($PID, $files, $date, $filesize, $datetime) = @_;
	my $count = 1;
	my $exec = "";
	
	log_error("exec_sql_insert_batch: PID=$PID", 2);
	
	if ($PID eq '')
	{
		log_error("exec_sql_insert_batch: error: PID empty", 0);
		return;
	}
	while ($_ = shift @$files)
	{
		my $str = "($PID," . quote($_) . ",$date,$filesize->{$_}," . quote($datetime->{$_}) . ")";
		$exec .= (($count++ > 1) ? ',' : 'INSERT INTO File VALUES ') . $str;
		log_error("[SQL] INSERT INTO File VALUES $str", 3);
		if ($count % $c{MAX_BATCH} == 0)
		{		
			exec_sql($exec, 0);
			$exec = "";
			$count = 1;
		}
	}
	
	exec_sql($exec, 0) if ($exec ne "");
}

sub exec_sql_delete_batch
{
	my ($PID, $files) = @_;
	my $count = 1;
	my $exec = "";
	
	log_error("exec_sql_delete_batch: PID=$PID", 2);
	
	while ($_ = shift @$files)
	{
		log_error("delete_batch: $_", 2);
		$exec .= ($count++ > 1) ? " OR FileName=" . quote($_)
		: "DELETE FROM File WHERE PID=$PID AND (FileName=" . quote($_);
		if ($count % $c{MAX_BATCH} == 0)
		{		
			exec_sql($exec.')', 1);
			$exec = "";
			$count = 1;
		}
	}
	
	exec_sql($exec.')', 1) if ($exec ne "");
}

sub ftp_get_listing
{
	my ($host, $login, $password, $port, $filehandle) = @_;
	
	log_error("ftp_get_listing: $login:$password\@$host:$port", 2);
	
	my $ftphandle = Net::FTP->new($host, Port => $port, Timeout => 15);
	if (!defined $ftphandle)
	{
		log_error("ftp_get_listing: $host unreachable, reason: $@", 1);
		return;
	}
	if ($login eq "anonymous" && ($password eq 'user@host.com'))
	{
		$password = $c{FTP_ANON_PW};
	}
	$ftphandle->login($login, $password);
	
	%symlinks = ();		# init symlink lookup table
	$symlinks{make_path($ftphandle->pwd())} = 1;
	
	ftp_scan_server('', $filehandle, $ftphandle, $ftphandle->pwd());
	$ftphandle->close();
}

sub make_path
{
	($_) = @_;
	
	s/\\/\//g;
	s/\/+/\//g;
	s/\/*$//;
	lc $_;
}

sub ftp_scan_server
{
	my ($subdir, $ftpcontent, $ftphandle, $basedir) = @_;
	
	log_error("ftp_scan_server: scanning $basedir/$subdir", 2);
	
	$ftphandle->cwd($basedir)
	    || (log_error("ftp_scan_server: could not change to basedir", 1)
		&& return);
	
	if ($subdir ne '' && (!$ftphandle->cwd($subdir)))
	{
		log_error("ftp_scan_server: broken link ($subdir)", 1);
		return;
	}
	
	print $ftpcontent "$subdir\n";
	
	my @out = $ftphandle->dir();
	my @scan = ();
	my @base = ();
	
	foreach (@out)
	{
		m/^\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+ (.*)$/;
		next unless my $filename = $1;
		next if (($filename eq ".") || ($filename eq ".."));
		if (m/^d/)
		{
			my $tmp = ($subdir eq '' ? $filename : "$subdir/$filename");
			push (@scan, $tmp);
		}
		elsif (m/^-/)
		{
			print $ftpcontent "\t$_\n";
		}
		elsif (m/^l/)
		{
			log_error("ftp_scan_server: link found: $filename", 2);
			my @parts = split / \-\> /, $filename;
			if (@parts != 2)
			{
				log_error("ftp_scan_server: fatal error: more than two parts splitting $1", 1);
				next;
			}
			
			$parts[1] = make_path($parts[1]);
			if (($subdir =~ /\Q$parts[0]/) || (defined $symlinks{$parts[1]}))
			{
				log_error("ftp_scan_server: looks like a symlink loop. skipping. ($parts[0])", 2);
				next;
			}
			$symlinks{$parts[1]} = 1;
			push @scan, ($subdir eq '' ? $parts[0] : "$subdir/$parts[0]");
		}
	}
	foreach (@scan)	
	{
		ftp_scan_server($_, $ftpcontent, $ftphandle, $basedir)
	}
}

sub timestamp
{
    my ($argvref) = @_;
	my $cmdline = $0 . ' ';
	
	foreach (@$argvref)
	{
		$cmdline .= $_ . ' ';
	}
	return ('-' x 80 .
	sprintf("\n%s, starting new crawl\nCommandline: %s\n", scalar localtime(time), $cmdline) .
	'-' x 80);
}

sub create_tables
{
    my $tables = $db->selectcol_arrayref("SHOW TABLES") ||
	die "Error listing tables - reason: $DBI::errstr\n";

    foreach (@$tables)
    {
	$db->do("DROP TABLE $_") ||
	    die "Error dropping table - reason: $DBI::errstr\n";
    }
	
    $db->do("CREATE TABLE Host (HID smallint unsigned AUTO_INCREMENT NOT NULL,\
	HostName CHAR(40) NOT NULL,\
	WorkGroup CHAR(40) NOT NULL,\
	HostType TINYINT UNSIGNED NOT NULL,\
	LastScan Date NOT NULL,\
	ExpireCount tinyint unsigned,\
	PreferedTime smallint, \
	KEY (HID))
	");
	
	$db->do("CREATE TABLE FTP (HostName CHAR(40) NOT NULL,\
	Login CHAR(20) NOT NULL,\
	PassWord CHAR(40) NOT NULL,\
	Port smallint unsigned NOT NULL,\
	Comment CHAR(200) NOT NULL)
	");
	
	$db->do("CREATE TABLE FTPNew (HostName CHAR(40) NOT NULL,\
	Login CHAR(20) NOT NULL,\
	PassWord CHAR(40) NOT NULL,\
	Port smallint unsigned NOT NULL)
	");
	
	$db->do("CREATE TABLE Share (SID int unsigned AUTO_INCREMENT NOT NULL,\
	ShareName CHAR(40) NOT NULL,\
	HID smallint unsigned NOT NULL,\
	KEY (SID))
	");
	
	$db->do("CREATE TABLE Path (PID int unsigned AUTO_INCREMENT NOT NULL,\
	PathName CHAR(180) NOT NULL,\
	HID smallint unsigned NOT NULL,\
	SID int unsigned NOT NULL,\
	KEY (PID))
	");
	
	$db->do("CREATE TABLE File (PID int unsigned NOT NULL, \
	FileName VARCHAR(90) NOT NULL,\
	DateAdded int unsigned NOT NULL,\
	FileSize int unsigned NOT NULL,\
	FileDate datetime NOT NULL,\
	KEY (PID))
	");
	
	$db->do("CREATE TABLE Status (Files int unsigned NOT NULL, FileSize char(10) NOT NULL,\
	SMBHosts smallint unsigned NOT NULL, FTPHosts smallint unsigned NOT NULL,\
	LastChange CHAR(20) NOT NULL)
	");
	$db->do("CREATE TABLE SMBtoIP (HostName CHAR(40) NOT NULL,
	IP CHAR(15) NOT NULL,
	KEY (HostName))
	
	");
}


sub log_error
{
	my ($log_error, $level) = @_;
	
	chomp $log_error;
	if ($level < 0)
	{
		print LOG "$log_error\n";
	}
	elsif ($level <= $c{DEBUGLEVEL})
	{
		print LOG "[$level] $log_error\n";
	}
}
