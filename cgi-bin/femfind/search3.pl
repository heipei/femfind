#!/usr/bin/perl

require 5.004;
use strict;
use POSIX qw(locale_h);
use locale;
use Time::HiRes qw (gettimeofday);
use CGI qw/-nodebug/;
use DBI;
use FemFind::ConfigReader qw(config_default config_read);
use FemFind::Helper qw(get_ip shell_escape);

my $q = new CGI;

my %smb_to_ip = my %host_alive = ();
config_default();    
my %c = config_read(1);

my $debug = 0;
$c{months} = {"Jan"=>0, "Feb"=>1, "Mar"=>2, "Apr"=>3, "May"=>4,
"Jun"=>5, "Jul"=>6, "Aug"=>7, "Sep"=>8, "Oct"=>9,
"Nov"=>10, "Dec"=>11};
$c{SMB} = 1;
$c{FTP} = 2;
$c{time_start} = gettimeofday;

my %user_env = $q->cookie(-name=>'settings');
$c{num_hits_displayed} = $q->param('hits');
$user_env{searchstring} = $c{searchstring} = $q->param('searchstring');
$_ = $c{mode_text} = $q->param('mode');
$user_env{mode} = $c{mode} = ($_ eq "normal" ? 0 : ($_ eq "wildcards" ? 1 : 2));
$user_env{online} = $c{online} = ($q->param('online') eq "on" ? 1 : 0);
$user_env{minfilesize} = $q->param('minfilesize');
$user_env{maxfilesize} = $q->param('maxfilesize');
$user_env{date} = $q->param('date') eq "on" ? 1 : 0;
$user_env{dateday} = $q->param('dateday');
$user_env{datemonth} = $q->param('datemonth');
$user_env{dateyear} = $q->param('dateyear');
$user_env{fskip} = $q->param('fskip') eq "on" ? 1 : 0;
$c{form} = $q->param('form');
$c{offset} = $q->param('offset') || 0;
$c{num_first} = $q->param('index') || 0;
$c{file_skip} = $q->param('fskip') || '';
$c{savestate} = $q->param('savestate');
my $cookie;

if ($c{num_first} == 0)
{
	$user_env{query9} = $user_env{query8};
	$user_env{query8} = $user_env{query7};
	$user_env{query7} = $user_env{query6};
	$user_env{query6} = $user_env{query5};
	$user_env{query5} = $user_env{query4};
	$user_env{query4} = $user_env{query3};
	$user_env{query3} = $user_env{query2};
	$user_env{query2} = $user_env{query1};
	$user_env{query1} = $user_env{query0};
	$_ = $c{searchstring};
	#s/'/''/g;
	$user_env{query0} = "\'$_\', $c{mode},".
	"$user_env{online}, 0, $user_env{date}, \'$user_env{dateday}\',".
	"\'$user_env{datemonth}\', \'$user_env{dateyear}\', \'$user_env{minfilesize}\', \'$user_env{maxfilesize}\',".
	"$user_env{fskip}";
	if ($c{savestate} eq "on")
	{
		$cookie = $q->cookie(-name=>'settings',
		-value=>\%user_env,
		-path=>"/",
		-expires=>"+3M");
		
	}
	else
	{
		if (defined $user_env{'searchstring'})
		{
			$cookie = $q->cookie(-name=>'settings',
			-value=>'deleting',
			-expires=>'-1d',
			-path=>"/");
		}
	}
}
if ($user_env{date})
{
	$c{startdate} = timelocal(0, 0, 0, $user_env{dateday}, $c{months}{$user_env{datemonth}}, $user_env{dateyear});
}
$c{num_last} = $c{offset} + $c{num_hits_displayed};
$_ = $q->self_url();
s/\&index=[0-9]*//;
s/\&fskip=o?n?//;
s/\&offset=[0-9]*//;
$c{url} = $_;
$c{limit} = "LIMIT $c{offset}, $c{num_last}";
if ($c{online})
{
	$c{online_pre} = '<img src="/femfind/';
	$c{online_post} = '.gif" height=12 width=12 border=0>';
}
$c{img_folder} = '<img src="/femfind/folder.gif" width=16 height=16>';
$c{img_doc} = '<img src="/femfind/doc.gif" width=16 height=16>';

##
## searchstring
##
if ($c{mode_text} eq "regex")
{
	$c{searchstring_files} = "FileName REGEXP \"$c{searchstring}\"";
	$c{searchstring_path} = "HostName REGEXP \"$c{searchstring}\" OR ShareName REGEXP \"$c{searchstring}\"\
	OR PathName REGEXP \"$c{searchstring}\"";
}
else
{
	if ($c{mode_text} eq "normal")
	{
		$c{searchstring} =~ s/(%|_)/\\$1/g;
	}
	else
	{
		$c{searchstring} =~ s/\*+/%/g;
		$c{searchstring} =~ s/\?/_/;
	}	
	
	my @and = my @or = ();
	while ($c{searchstring} =~ m/(\+"[^"]+"|"[^"]+"|\+[^+\s]+|[^+\s]+)/g)
	{
		my $tmp = $1;
		$_ = ($c{mode_text} eq "normal" ? "%$1%" : $1);
		s/^(%?)\+"/$1/;
		s/^(%?)\+/$1/;
		s/^(%?)"/$1/;
		s/"(%?)$/$1/;
		if ((substr $tmp, 0, 1) eq '+')
		{
			push @and, $_;
		}
		else
		{
			push @or, $_;
		}
	}
	my $or_file = my $and_file = "";
	
	foreach (@and)
	{
		$and_file .= " AND FileName LIKE \"$_\"";
	}
	$and_file =~ s/^ AND//;
	
	foreach (@or)
	{
		$or_file .= " OR FileName LIKE \"$_\"";
	}
	
	$or_file =~ s/^ OR (.*)$/ AND ($1)/;
	$or_file =~ s/^ AND // if ($and_file eq '');
	
	$c{searchstring_files} = "($and_file$or_file)";
	$and_file =~ s/FileName/PathName/og;
	$or_file =~ s/FileName/PathName/og;
	$c{searchstring_path} = "($and_file$or_file)";
	$and_file =~ s/PathName/ShareName/og;
	$or_file =~ s/PathName/ShareName/og;
	$c{searchstring_path} .= " OR ($and_file$or_file)";
	$and_file =~ s/ShareName/Host.HostName/og;
	$or_file =~ s/ShareName/Host.HostName/og;
	$c{searchstring_path} .= " OR ($and_file$or_file)";
}

if ($user_env{date})
{
	$c{searchstring_files} .= " AND DateAdded>$c{startdate}";
}
if ($user_env{minfilesize} =~ m/^\s*(\d+)\s*$/)
{
	$c{searchstring_files} .= " AND FileSize>$1";
}
if ($user_env{maxfilesize} =~ m/^\s*(\d+)\s*$/)
{
	$c{searchstring_files} .= " AND FileSize<$1";
}

my $style = "
.b  { text-decoration:none; color:#000000; font-family: Verdana,Arial,Helvetica; font-size: 11px;}\
A   { text-decoration:none; color:#0033ff; font-family: Verdana,Arial,Helvetica; font-size: 11px;}\
a:link, a:visited {text-decoration:none}";


print $q->header(-cookie=>$cookie),
$q->start_html({-title => "FemFind - To search is human, to find divine ;)",
-bgcolor=>"#dddddd",
-style=>"$style"});
print "$cookie" if ($debug);
$_ = $q->param('searchstring');

print qq{
<table width="100%" border="0" cellspacing="0" cellpadding="1">
<tr bgcolor="#888888">
<td valign="top">
<table border="0" cellspacing="0" cellpadding="3" width="100%">
<tr bgcolor="#99CCFF">
<td valign="top" class="b"><b>Ergebnis f&uuml;r [$_]</b></td>
</tr>
<tr bgcolor="#dddddd">
<td valign="top" class="b">
<font face="helvetica,verdana,arial" size="3" color="#303088">
};					

debug() if ($debug);

##
## start search
##
$c{hits} = 0;
$c{files_left} = 0;
my ($output, %PID, %FTP);

my $db = DBI->connect($c{DB}, 'search') || die $DBI::errstr;

if ($c{online})
{   
	my $cmd = $db->prepare("SELECT HostName, IP FROM SMBtoIP");
	$cmd->execute();
	while (my @row = $cmd->fetchrow_array())
	{
		$smb_to_ip{$row[0]} = $row[1];
	}
}

if ($c{file_skip} ne 'on')
{
	my $pids = $db->selectcol_arrayref("select PID from File where $c{searchstring_files} $c{limit}");
	if (@$pids > 0)
	{
		my $pid_string = "";
		my %tmp_pid = ();
		foreach (@$pids)
		{
			next if ($tmp_pid{$_} == 1);
			$tmp_pid{$_} = 1;
			$pid_string .= " OR PID=$_";
		}	
		$pid_string =~ s/^ OR//;
		
		print "$pid_string" if ($debug);
		my $hostname_string = "";
		my $cmd = $db->prepare("SELECT HostName, ShareName, PathName, HostType, PID from Path natural left join Share natural left join Host where $pid_string");
		$cmd->execute();
		while (my @row = $cmd->fetchrow_array())
		{
			$host_alive{$row[0]} = '';
			$PID{$row[4]} = \@row;
			if ($row[3] == $c{FTP})
			{
				$hostname_string .= " OR HostName=\"$row[0]\"";
			}
		}
		$hostname_string =~ s/^ OR//;
		print "hn: $hostname_string<br>" if ($debug);
		if ($hostname_string ne '')
		{
			my $cmd = $db->prepare("SELECT HostName, Login, PassWord, Port from FTP WHERE $hostname_string");
			$cmd->execute();
			while (my @row = $cmd->fetchrow_array())
			{	$_ = shift @row;
				print "ftpc: $_<br>" if ($debug);
				if ($row[0] eq 'anonymous' && $row[1] eq 'user@host.com')
				{
					$FTP{$_} = "$_\:$row[2]";
				}
				else
				{
					$FTP{$_} = "$row[0]:$row[1]\@$_:$row[2]";
				}
			}
		}
		
		if ($c{online})
		{
			foreach (keys %host_alive)
			{
				$host_alive{$_} = host_alive($_); 
			}
		}
		
		$cmd = $db->prepare("select PID,FileName,FileSize,FileDate from File where $c{searchstring_files} $c{limit}");
		$cmd->execute();
		
		while ($c{hits} < $c{num_hits_displayed} && (my @out = $cmd->fetchrow_array()))
		{
			# could be removed, indicates something´s wrong with the cache
			if (!defined $PID{$out[0]})
			{
				print "hits: $c{hits}<br>" if ($debug);
				$output .= "!!ERROR<br>";
				die "cache error\n";		
			}
			
			if ($PID{$out[0]}->[3] == $c{SMB})
			{
				$_ = $PID{$out[0]};
				my $path = "file://$_->[0]/$_->[1]$_->[2]/";            									
				my $out = "$c{online_pre}$host_alive{$_->[0]}$c{online_post}$c{img_doc}" .
				$q->a({-href => $path, target => "ff_res"}, $path) .
				'&nbsp'.
				$q->a({-href => "$path$out[1]"}, $out[1]) .
				$q->font({-size=>"2", -color=>"#888888"}, "&nbsp;&nbsp;&nbsp;&nbsp;$out[2] | $out[3]") .
				$q->br;
				$output .= $out;
			}
			else
			{
				$_ = $PID{$out[0]}->[0];
				if (!defined $FTP{$_})
				{
					#$output .= "ftp error: $_<br>"
				}
				my $path = "/$PID{$out[0]}->[2]/";
				
				my $out = "$c{online_pre}$host_alive{$_}$c{online_post}" .
				$c{img_doc} .
				$q->a({-href => "ftp://$FTP{$_}$path", target => "ff_res"}, "ftp://$_$path") .
				'&nbsp;' .
				$q->a({-href => "ftp://$FTP{$_}$path$out[1]"}, $out[1]) .
				$q->font({-size=>"2", -color=>"#888888"}, "&nbsp;&nbsp;&nbsp;&nbsp;$out[2] | $out[3]") . $q->br;
				$output .= $out;
			}
			$c{hits}++;
			$c{offset}++;
		}
	}
}
if ($c{hits} < $c{num_hits_displayed})
{
	# now continue the search in host/share/pathnames
	if ($c{file_skip} ne 'on')
	{
		$c{files_left} = $c{num_hits_displayed} - $c{hits} + 1;
		$c{limit} = "LIMIT 0, $c{files_left}";
		$c{file_skip} = 'on';
		$c{offset} = 0;
	}
	else
	{
	}
	my $cmd = $db->prepare("SELECT Host.HostName, ShareName, PathName, HostType, Login, PassWord, Port FROM Path natural left join Share natural left join Host natural left join FTP WHERE $c{searchstring_path} $c{limit}");
	$cmd->execute();
	
	while ($c{hits} < $c{num_hits_displayed} && (my @row = $cmd->fetchrow_array()))
	{
		if ($c{online} && !defined $host_alive{$row[0]})
		{
			$host_alive{$row[0]} = host_alive($row[0]);
		}
		if ($row[3] == $c{SMB})
		{
			my $line = "file://$row[0]/$row[1]$row[2]/";
			my $out = "$c{online_pre}$host_alive{$row[0]}$c{online_post}  " .
			$c{img_folder} . $q->a({-href => $line, target => "ff_res"}, $line) . $q->br;
			$output .= $out;
		}
		else
		{
			my $line = "/$row[1]$row[2]/";
			my $prefix = ($row[4] eq 'anonymous' && $row[5] eq 'user@host.com') ?
			'' : "$row[4]:$row[5]\@";
			my $out = "$c{online_pre}$host_alive{$row[0]}$c{online_post}  " .
			$c{img_folder} .
			$q->a({-href => "ftp://$prefix$row[0]:$row[6]$line", target => "ff_res"}, "ftp://$row[0]$line") .
			$q->br;
			$output .= $out;
		}
		$c{hits}++;
		$c{offset}++;
	}
}

$c{num_last} = $c{num_first} + $c{hits};
print "hits: $c{hits}" if ($debug);
if ($c{hits} == $c{num_hits_displayed})
{
	$c{control} .= $q->a({-href => "$c{url}&offset=$c{offset}&index=$c{num_last}&fskip=$c{file_skip}&form=$c{form}"}, "Mehr..."). " | ";
}
$c{control} .= $q->a( {-href => "frontpage.pl?form=$c{form}"}, "Neue Suche" );

$c{num_last}--;
my $treffer;
$treffer = "Treffer $c{num_first} - $c{num_last}:" if ($c{hits} > 1);
$treffer = "Treffer $c{num_first}:" if ($c{hits} == 1);
$treffer = "Keine Treffer." if ($c{hits} == 0);

print qq{
$c{control}
<p>
<i><font color="#902020">$treffer</font></i>
<p>
$output
};

my $time = sprintf "%.2f", gettimeofday-$c{time_start};
print qq{
<p>
<b>$c{hits} Treffer in $time sec</b>
<p>
$c{control}
</font>
</td>
</tr>
<tr bgcolor="#99CCFF">
<td valign="top" class="b">FemFind v$c{VERSION} [$c{VDATE}] Copyright Martin Richtarsky
[<a href="http://www.codefactory.de/">www</a>|<a href="mailto:femfind\@codefactory.de">mail</a>]
</td>
</tr>
</table>
</td>
</tr>
</table>
};

$db->disconnect();
print $q->end_html;

sub debug
{
	print $q->h1("c:"), $q->p;
	foreach (sort keys %c)
	{
		print "$_ = $c{$_}<br>";
	}
	
	print $q->h1("user_env:"), $q->p;
	foreach (sort keys %user_env)
	{
		print "$_ = $user_env{$_}<br>";
	}
}

sub host_alive
{
	print "host alive:$_[0]" if ($debug);
	my $ip = '';
	if (!defined ($ip = $smb_to_ip{$_[0]}))
	{
		$ip = get_ip($_[0], '', $c{SMB_PATH}, $c{SMB_ACCPARAM}, $debug, *STDIN);
	}
	return (`ping -c1 -i1 -w1 $ip 2>/dev/null` =~ m/time/) ? "online" : "offline";
}
