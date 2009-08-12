#!/usr/bin/perl

#
# reformatted 13.07.2000, 02:19
#

use strict;
use CGI qw/-nodebug/;
use FemFind::ConfigReader qw(config_default config_read);
use FemFind::Helper qw(get_ip);

config_default();   
my %c = config_read();

my $q = new CGI;
my $cmd = $q->param('command');

if ($cmd eq 'list')
{
    display_ftps_in_database();
}
elsif ($cmd eq 'add')
{
    add_ftp();
}

sub add_ftp
{
    print $q->header;
    my $host = uc $q->param('host');
    my $login = $q->param('login');
    my $password = $q->param('password');
    my $port = $q->param('port');
    my $comment = $q->param('comment');
    
    open (IN, "template_addftp.html");
    my @html = <IN>;
    my $output = join('', @html); 
    close IN;

    my $errormsg = '';
    
    $errormsg .= "Host is missing.<br>" if (!defined $host || $host eq '');
    $errormsg .= "Login is missing.<br>" if (!defined $login);
    $errormsg .= "Password is missing.<br>" if (!defined $password);
    $errormsg .= "Port is missing.<br>" if (!defined $port);
    $errormsg .= "Port is invalid.<br>" if ($port < 1 && $port > 65535);
	if (!defined get_ip($host, '', $c{SMB_PATH}, $c{SMB_ACCPARAM}, 0))
	{
  		$errormsg .= "Invalid WINS, DNS name or IP.<br>";
	}
    
    if ($errormsg ne '')
    {
	$output =~ s/#ftp/$errormsg/;
    }
    else
    {
	my @list = read_ftp_list();
	my $index = 0;
	push @list, join ('#__', ($host, $login, $password, $port, $comment)). "\n";
	write_ftp_list(\@list);
	$output =~ s/#ftp/Host has been added./;
    }
     
    print $output;
}

sub read_ftp_list
{
    open (IN, "<$c{FTPFILE}/ftp_list");
    my @list = <IN>;
    close IN;
    return @list;
}

sub write_ftp_list
{
    (my $list) = @_;
    
    open (OUT, ">$c{FTPFILE}/ftp_list") || die "$!";
    foreach (@$list)
    {
	print OUT "$_";
    }
    close OUT;
}

sub display_ftps_in_database
{
    print $q->header;

    open (IN, "template_ftp.html");
    my @html = <IN>;
    $_ = join('', @html); 
    close IN;

    my ($table, $lopen, $lclose);
    my $fopen = '<td class="b">';
    my $fclose = '</td>';
    my $hopen = '<th align="left" bgcolor="#cccccc"><font face="verdana, helvetica" size="2">';
    my $hclose = '</font></th>';

    my @list = read_ftp_list();
    foreach (sort @list)
    {
	chomp;
	my @parts = split(/#__/, $_);

	# netscape workaround for empty rows
	for (my $i = 0; $i < 5; $i++)
	{
	$parts[$i] = '&nbsp;' if ((!defined $parts[$i]) || ($parts[$i] eq ''));
	}

#	ftp links deactivated
#	if ($parts[1] eq "anonymous" && $parts[2] eq "user\@host.com")
#	{
#	    $lopen = "<a href=\"ftp://$parts[0]:$parts[3]/\">";
#	}
#	else
#	{
#	    $lopen = "<a href=\"ftp://$parts[1]:$parts[2]\@$parts[0]:$parts[3]/\">";
#	}
#	$lclose = "</a>";
	
	$table .= qq{
	<tr bgcolor="#e0e0e0">
	$fopen$lopen$parts[0]$lclose$fclose$fopen$parts[1]$fclose$fopen$parts[2]$fclose
	<td align="right" class="b" bgcolor="#dddddd">$parts[3]$fclose$fopen$parts[4]$fclose
	</tr>
	};	
    }
    if (@list == 0)
    {
	s/#num_ftps/No hosts./;
	s/#ftp/&nbsp;/;
    }
    else
    {
	my $header = qq{<table cellpadding=3 cellspacing=1 border=0 width="500">
			<tr width="500">
			$hopen Host $hclose
			$hopen Login $hclose
			$hopen Password $hclose
			$hopen Port $hclose
			$hopen Comment $hclose
			</tr>
			};
	my $trailer = sprintf "[%d Server]", $#list+1;

	$table = $header . $table . '</table>';
	s/#ftp/$table/;
	s/#num_ftps/$trailer/;
    }

    print $_;
}
