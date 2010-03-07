#!/bin/sh
#
# Simple FemFind install script.
# Version 0.74, Last modified: 23.11.2000
#

echo "Looking for your perl..."
PERLPATH=`which perl`
OLD='#!/usr/bin/perl'
NEW="#!$PERLPATH"
echo $NEW >replace.pl

chmod u+x replace.pl
cat replace >>replace.pl
P1=cgi-bin/femfind
P2=german
for FILE in $P1/ftp.pl $P1/frontpage.pl $P1/search3.pl $P2/ftp.pl $P2/search3.pl\
	    crawler.pl makedb.pl
do
    echo "Adjusting perl path in $FILE"
    ./replace.pl $FILE $OLD $NEW
done
rm replace.pl

echo
echo 'Should I try to install these Perl modules via CPAN?'
echo '	DBI, Bundle::DBD::mysql, Net::FTP (part of libnet), Time::HiRes';
echo -n '(y/n) '
LOOP='1'
while [ $LOOP = '1' ]
do
  read a
  if [ $a = 'y' -o $a = 'Y' ]
  then
	INSTALL='1'
	LOOP='0'
  elif [ $a = 'n' -o $a = 'N' ]
  then
	INSTALL='0'
	LOOP='0'
  fi
done

if [ $INSTALL = '1' ]
then
  echo 'Installing Perl modules...'
  echo
  perl -MCPAN -e 'install DBI, Bundle::DBD::mysql, Time::HiRes, Net::FTP' || exit 1;
fi

echo
echo 'Installing ConfigReader.pm'
cd modules
./makemod || exit 1;
cd ..

echo
echo "Installing femfind.conf"
cp /etc/femfind.conf /etc/femfind.conf.backup
install -m 644 femfind.conf /etc/femfind.conf

echo
echo "Configuring database..."
./makedb.pl
