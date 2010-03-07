#!/usr/bin/perl
#
# Creates the necessary database settings (MySQL). Used by install.sh.
#

use DBI;
use Getopt::Long;
use FemFind::ConfigReader qw(config_default config_read config_check
			     config_error);
use strict;
use vars qw($opt_help $opt_user $opt_password $opt_enable_winclients
	    $opt_femfind_password $opt_quiet);

my $version = "0.1";

my %c = ();
my $in;
%c = config_default();
%c = config_read(1);
if (config_check != 0)
{
    config_error();
    exit 1;
}

print "About to create database '$c{DB_NAME}'.\n",
      "For a different name, edit $c{CONFIG_FILE} (parameter db_name) and rerun.\n\n";
      
GetOptions("user=s", "password=s", "femfind-password=s", 
	   "enable-winclients", "help", "quiet");
print $opt_help, $opt_password, $opt_user, $opt_enable_winclients;

if ($opt_help)
{
    help();
    exit 0;
}

if ($opt_user eq '')
{
    print "MySQL user (must be able to access the 'mysql' database) [root]: ";
    chomp ($opt_user = <STDIN>);
    $opt_user = 'root' if ($opt_user eq '');
}
if ($opt_password eq '')
{
    print "Password: ";
    system('stty -echo');
    chomp ($opt_password = <STDIN>);
    system('stty echo');
    print "\n";
}
if ($opt_femfind_password eq '')
{
    print "Password for the '$c{DB_CRAWLER_LOGIN}' user account: ";
    system('stty -echo');
    chomp ($opt_femfind_password = <STDIN>);
    system('stty echo');
    print "\n";
}

if (!$opt_enable_winclients && !$opt_quiet)
{
    print "Do you want to use the Windows clients for searching? (y/n) [Y]: ";
    chomp($in = <STDIN>);    
    $opt_enable_winclients = 1 if ($in eq '' || $in =~ /^y$/i);
}

my $db = DBI->connect($c{DB_BASE} . 'mysql', $opt_user, $opt_password) ||
    die "Could not connect to database - reason: $DBI::errstr\n";

my $dbs = $db->selectcol_arrayref("SHOW DATABASES");
my $delete_tables = 0;
foreach (@$dbs)
{
    if ($_ eq $c{DB_NAME})
    {
	$delete_tables = 1;
	print "Database '$c{DB_NAME}' already exists.\n",
	      "Delete all tables and rebuild it? (y/n) [N]: ";
	chomp(my $answer = <STDIN>);
	if ($answer !~ /^y$/i)
	{
	    $delete_tables = 2;
	}
	last;
    }
}

if ($delete_tables == 0)
{
    $db->do("CREATE DATABASE $c{DB_NAME};") ||
	die "Could not create database '$c{DB_NAME}' - reason: $DBI::errstr\n";
}

print "Writing account info...\n";

#
# femfind account (full rights)
#
my $insert_db = $db->quote($c{DB_CRAWLER_LOGIN}) .
		", PASSWORD(" . $db->quote($opt_femfind_password) . ') ' .
		", 'Y'" x 6 . ", 'N'" x 8;
$db->do("INSERT INTO user VALUES ('localhost', $insert_db)") ||
    print "Error while inserting - reason: $DBI::errstr\n";

#
# search account
#
$insert_db = "'search', '', 'Y'" . ", 'N'" x 13;
$db->do("INSERT INTO user VALUES ('localhost', $insert_db)") ||
    print "Error while inserting - reason: $DBI::errstr\n";
if ($opt_enable_winclients)
{
    $db->do("INSERT INTO user VALUES ('%', $insert_db)") ||
	print "Error while inserting - reason: $DBI::errstr\n";
}

$db->do("INSERT INTO db VALUES ('%'," . $db->quote($c{DB_NAME}) .
	 ", ''" . ", 'N'"  x 10 . ")") ||
    print "Error while inserting - reason: $DBI::errstr\n";


if ($delete_tables != 2)
{	
    print "Creating tables...\n";
    $db->do("USE $c{DB_NAME};");
    create_tables() 
}

$db->disconnect();

print "Inserting your password into crawler.pl...\n";
replace('crawler.pl', 'my $DB_CRAWLER_PASSWORD = ',
	"my \$DB_CRAWLER_PASSWORD = '$opt_femfind_password';\n");

print "Reload MySQL privileges? (y/n) [Y]: ";
chomp($in = <STDIN>);
if ($in =~ /^y$/i || $in eq '')
{
    my $pass = $opt_password eq '' ? '' : "-p$opt_password";
    system("mysqladmin -u$opt_user $pass reload");
    if ($? >> 8 != 0)
    {
	print "An error occured. Try to manually reload privileges using mysqladmin.\n";
    }
}
print "\nInstallation completed.\n";
exit(0);


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

sub replace
{
    my ($file, $find, $replace) = @_;
    
    open (IN, "<$file");
    my @content = <IN>;
    close IN;
    
    open (OUT, ">$file");
    foreach (@content)
    {
	if ($_ =~ /^\Q$find/)
	{
	    print OUT $replace;
	}
	else
	{
	    print OUT $_;
	}
    }
    close OUT;
}

sub help
{
    print <<END;
FemFind makedb.pl v$version -- creates database and users for FemFind.

Usage: makedb.pl [options]

    --user		MySQL user with access to the 'mysql' database
    --password		password for that user
    --enable-winclients	allow remote access to the 'search' account
    --femfind-password	password for the crawler user account (full rights)
    --quiet		no explicit questions if options aren't specified
    --help		display this text


This script will be invoked by install.sh and sets up the femfind database
and two users.
END
}

