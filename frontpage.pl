#!/usr/bin/perl

use strict;
use DBI;
use CGI qw/-nodebug/;
use FemFind::ConfigReader qw(config_default config_read);

my $q = new CGI;
print $q->header;
my %user_env = $q->cookie('settings');

config_default();
my %c = config_read(1);

my $prev = "| ";
my $prev_add = "";

my $prev_start = qq{
    <table width="620" border="0" cellspacing="0" cellpadding="1">
    <tr bgcolor="#888888">
        <td valign="top">
	<table width="618" border="0" cellspacing="0" cellpadding="4">
            <tr bgcolor="#99CCFF">
	    <td valign="top" class="b"><b>Your History</b></td>
            </tr>
            <tr bgcolor="#f0f0f0">
            <td valign="top" class="b">
};

my $prev_end = qq{
	    </td>
            </tr>
	</table>
        </td>
	</tr>
    </table>
    <br>
};

my $mode = $q->param('form');
my $file;
if ($mode eq 'advanced')
{
    $file = 'template_advanced';
}
elsif ($mode eq 'help')
{
    $file = 'template_help';
}
else
{
    $file = 'template_basic';
}
    
open (IN, "<$file.html");
my @html = <IN>;
close IN;
$_ = join('', @html);

if (!defined %user_env)
{
    s/#searchstring//;
    s/#chk_normal/ checked/;
    s/#chk_wildcards//;
    s/#chk_regex//;
    s/#chk_online//;
    s/#chk_startdate//;
    s/#chk_cookie//;
    s/#minfilesize//;
    s/#maxfilesize//;
    s/#query[0-9]//g;
    s/#previous_searches//;
    s/#chk_fskip//;
}
else
{
    my $sel = " selected";
    my $chk = " checked";    	
    my $chk_normal = "";
    my $chk_wildcards = "";
    my $chk_regex = "";
    ($user_env{mode} == 0) ? $chk_normal = $sel :
			    ($user_env{mode} == 2 ? $chk_regex = $sel : $chk_wildcards = $sel);
    my $searchstring = $user_env{searchstring};
    my $chk_online = ($user_env{online} == 1) ? $chk : "";
    my $chk_startdate = ($user_env{date} == 1) ? $chk : "";
    my $chk_fskip = ($user_env{fskip} == 1) ? $chk : "";	
    s/#searchstring/$searchstring/;
    s/#chk_normal/$chk_normal/;
    s/#chk_wildcards/$chk_wildcards/;
    s/#chk_regex/$chk_regex/;
    s/#chk_online/$chk_online/;
    s/#chk_startdate/$chk_startdate/;
    s/#chk_cookie/$chk/;
    s/#chk_fskip/$chk_fskip/;
    s/#minfilesize/$user_env{minfilesize}/;
    s/#maxfilesize/$user_env{maxfilesize}/;
    s/(option)(> $user_env{datemonth})/\1 selected\2/;
    s/(option)(> $user_env{dateday})/\1 selected\2/;
    s/(option)(> $user_env{dateyear})/\1 selected\2/;
	
    for (my $i = 0; $i < 10; $i++)
    {
	my $content = $user_env{"query$i"};
	if ($content ne "")
	{
	    s/"#query$i"/$content/;
	    $content =~ s/^'(.*?[^\\])'.*/\1/;
	    $prev_add .= "<a href=\"javascript:suche($i)\">$content</a> | ";
	}
	else
	{
	    s/"#query$i"/$content/;
	}
    }

    $prev_add ne "" ? s/#previous_searches/$prev_start$prev$prev_add$prev_end/ : s/#previous_searches//;
}

my $db = DBI->connect($c{DB}, "search") ||
    mysql_down();
(my $num_files, my $sum_filesize, my $smb_hosts, my $ftp_hosts,
 my $max_dateadded) = $db->selectrow_array("SELECT * FROM Status");
 
my $upt = $db->prepare("SHOW STATUS");
$upt->execute();

my @row = (), my $queries = '&nbsp;', my $tm, my $found = 0;

while ($found < 2 && (@row = $upt->fetchrow_array()))
{
    if ($row[0] eq "Uptime")
    {
	$tm = $row[1];
	++$found;
    }
    elsif ($row[0] eq "Questions")
    {
	$queries = $row[1];
	++$found;
    }
}
my $u_sec = $tm % 60;
$tm /= 60;
my $u_min = $tm % 60;
$tm /= 60;
my $u_hour = $tm % 24;
$tm /= 24;
my $u_day = $tm % 30;
my $u_month = int($tm/30);

$upt->finish();
$db->disconnect();

s/#num_files/$num_files/;
s/#sum_filesize/$sum_filesize/;
s/#smb_hosts/$smb_hosts/;
s/#ftp_hosts/$ftp_hosts/;
s/#max_dateadded/$max_dateadded/;
s/#uptime/${u_month}m&nbsp;${u_day}d&nbsp;${u_hour}h&nbsp;${u_min}m/;
s/#queries/$queries/;
print $_;

sub mysql_down
{
    open(IN, "<template_dbdown.html") ||
	(print "Error: MySQL server down, Please contact your administrator!" && exit 1);
    my @content = <IN>;
    my $backup_url;
    if ($c{BACKUP_URL} ne '')
    {
	$backup_url = 'Please use this <a href="' . $c{BACKUP_URL} . '">backup server</a>.';
    }
    else
    {
	$backup_url = 'Please contact your administrator!';
    }
    my $html = join(' ', @content);
    $html =~ s/#backup_url/$backup_url/;
    print $html;
    close IN;
    exit 0;
}
