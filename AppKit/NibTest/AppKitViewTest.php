<?php

$GLOBALS['debug']=isset($_GET['DEBUG']) && (strcasecmp($_GET['DEBUG'], "yes") == 0);

// don't touch
global $ROOT;
$ROOT=preg_replace('|(.*/)(QuantumSTEP/)(.*)|i', '$1$2', __FILE__);

require_once "$ROOT/System/Library/Frameworks/AppKit.framework/Versions/Current/php/AppKit.php";
require_once "$ROOT/System/Library/Frameworks/Message.framework/Versions/Current/php/Message.php";

class AppController extends NSObject
{
	public $mainWindow;
	public $to;
	public $subject;
	public $body;
	public $status;

	public function checkAddress(NSObject $sender)
		{
		$status=NSMailDelivery::isEmailValid($this->to->stringValue());
		$this->status->setStringValue($status?"Valid":"Not Valid");
		}

	public function sendTheMail(NSObject $sender)
		{
		$status=NSMailDelivery::deliverMessageSubjectTo($this->body->string(), $this->subject->stringValue(), $this->to->stringValue());
		$this->status->setStringValue($status?"Sent":"Not Sent");
		}

	public function numberOfRowsInTableView(NSTableView $table)
		{
		return 5;
		}

	public function tableView_objectValueForTableColumn_row(NSTableView $table, NSTableColumn $column, $row)
		{
		return $column->identifier()." ".$row;
		}

function didFinishLoading()
	{

	$GLOBALS['NSApp']->setMainMenu(null);	// no main menu

	$this->mainWindow=new NSWindow("Mail");

	$grid=new NSCollectionView(2);
	$tf=new NSTextField();
	$tf->setAttributedStringValue("To:");
	$grid->addSubview($tf);
	$this->to=new NSTextField();
	$grid->addSubview($this->to);

	$tf=new NSTextField();
	$tf->setAttributedStringValue("Subject:");
	$grid->addSubview($tf);
	$this->subject=new NSTextField();
	$grid->addSubview($this->subject);

	$tf=new NSTextField();
	$tf->setAttributedStringValue("Message:");
	$grid->addSubview($tf);
	$this->body=new NSTextView();
	$grid->addSubview($this->body);

	$this->mainWindow->contentView()->addSubview($grid);

	$grid=new NSCollectionView(3);

	$button=new NSButton();
	$button->setTitle("Check Address");
	$button->setActionAndTarget('checkAddress', $this);
	$grid->addSubview($button);

	$button=new NSButton();
	$button->setTitle("Send Mail");
	$button->setActionAndTarget('sendTheMail', $this);
	$grid->addSubview($button);

	$this->status=new NSTextField();
	$this->status->setAttributedStringValue("New Mail");
	$grid->addSubview($this->status);

	$v=new NSPopUpButton();
	$grid->addSubview($v);
	$v->addItemWithTitle("item 1");
	$v->addItemWithTitle("item 2");
	$v->addItemWithTitle("item 3");

	$button=new NSButton();
	$button->setButtonType("Radio");
	$button->setTitle("Radio");
	$grid->addSubview($button);

	$button=new NSButton();
	$button->setButtonType("Checkbox");
	$button->setTitle("Checkbox");
	$grid->addSubview($button);

	$v=new NSTabView();
	$grid->addSubview($v);
	$c=new NSButton();
	$c->setTitle("first Button");
	$v->addTabViewItem(new NSTabViewItem("1", $c));
	$c=new NSButton();
	$c->setTitle("second Button");
	$v->addTabViewItem(new NSTabViewItem("2", $c));

	$v=new NSTableView(array("first", "second", "third"));
	$v->setDataSource($this);
	$grid->addSubview($v);

	$this->mainWindow->contentView()->addSubview($grid);

	}
}

NSApplicationMain("Zeiterfassung");

// EOF
?>