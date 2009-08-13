var hist = new Array();
hist[0] = new Array("#query0");
hist[1] = new Array("#query1");
hist[2] = new Array("#query2");
hist[3] = new Array("#query3");
hist[4] = new Array("#query4");
hist[5] = new Array("#query5");
hist[6] = new Array("#query6");
hist[7] = new Array("#query7");
hist[8] = new Array("#query8");
hist[9] = new Array("#query9");

function suche(nr)
{
	sc = document.search;
	if (hist[nr].length < 5)
		return;
	sc.searchstring.value = hist[nr][0];
	sc.mode.selectedIndex = hist[nr][1];
	sc.online.checked = hist[nr][2];
	sc.date.checked = hist[nr][4];
	sc.minfilesize.value = hist[nr][8];
	sc.maxfilesize.value = hist[nr][9];
	sc.fskip.checked = hist[nr][10];
	setIndexToText(hist[nr][5], sc.dateday);
	setIndexToText(hist[nr][6], sc.datemonth);
	setIndexToText(hist[nr][7], sc.dateyear);
}

function setIndexToText(txt, obj)
{
	var i = 0;	
	var found = 0;
	
	while (i < obj.options.length && found == 0)
	{
   		if (obj.options[i].text == txt)
   		{
   			obj.selectedIndex = i;
   			found = 1;
   		}
   		i++;
   	}
}

