(load "~/quicklisp/setup.lisp")
(require 'usocket)
(require 'bordeaux-threads)

(defparameter *irc-server* "irc.server.net")
(defparameter *irc-server-port* 6667)
(defparameter *irc-server-timeout* 500)
(defparameter *irc-password* nil)
(defparameter *irc-nick* "apostate-bot")
(defparameter *irc-user* "apostate-bot")
(defparameter *irc-mode* "8")
(defparameter *irc-realname* "apostate-bot")
(defparameter *irc-channel-list* '("#your_channel"))

(defparameter *server-socket* nil)
(defparameter *server-stream* nil)
(defparameter *bot-random-state* (make-random-state t))

(defparameter *abuse-cur-input* nil)
(defparameter *abuse-cur-time* 0)
(defparameter *abuse-prv-input* nil)
(defparameter *abuse-prv-time* 0)
(defparameter *abuse-flood-flag* 0)
(defparameter *abuse-pen-box* nil)

(defparameter *bot-repo* "https://github.com/slinkish/apostasy")
(defparameter *bot-thread* nil)
(defparameter *bot-owner* nil)
(defparameter *bot-break* nil)
(defparameter *bot-debug* nil)
;; Register bot commads here, prefix command with "bot-cmd-" in function definition
(defparameter *bot-cmds* '(sheep?
			   piss-off
			   master
			   soul
			   accept
			   no
			   cancel
			   r))
;; Roulette globals
(defparameter *r-challenger* nil)
(defparameter *r-challenged* nil)
(defparameter *r-accept-p* nil)
(defparameter *r-chamber* 6)
(defparameter *r-timeout* 259200)
(defparameter *r-timer* (- (get-universal-time) (+ *r-timeout* 10)))

(defun start-bot ()
  (setf *bot-thread* (bordeaux-threads:make-thread #'bot-run :name "bot")))

(defun bot-run ()
  (let ((active-time (get-universal-time))
	(backoff-time 10))
    (labels ((irc-server-connect ()
	       (setf *bot-break* nil)	     
	       (setf *server-socket* (usocket:socket-connect *irc-server* *irc-server-port*))
	       (setf *server-stream* (usocket:socket-stream *server-socket*))
	       (irc-server-register *server-stream* 
				    *irc-nick* 
				    *irc-user*
				    *irc-realname*
				    *irc-mode*
				    *irc-password*)
	       (irc-auto-chan-join *server-stream* *irc-channel-list*))
	     (irc-server-quit ()
	       (usocket:socket-close *server-socket*))
	     (irc-server-reconnect ()
	       (let ((active-delta (- (get-universal-time) active-time)))
		 (irc-server-quit)
		 (format t "Disconnected from server.~%")
		 (if (< active-delta (+ 10 backoff-time))
		     (incf backoff-time backoff-time)
		     (setf backoff-time 10))
		 (cond ((<= backoff-time 1800)
			(format t "Reconnecting in ~A seconds.~%" backoff-time)
			(sleep backoff-time)
			(irc-server-connect)
			(setf active-time (get-universal-time)))
		       (t
			(format t "Reconnecting in ~A minutes.~%" 30)
			(sleep 1800)
			(irc-server-connect)
			(setf active-time (get-universal-time))))))
	     (irc-server-read (server-stream)
	       (handler-case (read-line server-stream)
		 (end-of-file () (progn 
				   (irc-server-reconnect)
				   (irc-server-read *server-stream*)))
		 (timeout-error () (progn
				     (irc-server-reconnect)
				     (irc-server-read *server-stream*)))
		 (usocket:timeout-error () (progn
					     (irc-server-reconnect)
					     (irc-server-read *server-stream*)))
		 (usocket:ns-try-again-condition () (progn
						      (irc-server-reconnect)
						      (irc-server-read *server-stream*)))
		 (stream-is-closed-error () (progn
					      (irc-server-reconnect)
					      (irc-server-read *server-stream*)))
		 (unknown-error () (progn
				     (irc-server-reconnect)
				     (irc-server-read *server-stream*)))
		 (socket-creation-error () (progn
					     (irc-server-reconnect)
					     (irc-server-read *server-stream*)))
		 (socket-error () (progn
				    (irc-server-reconnect)
				    (irc-server-read *server-stream*))))))
      (setf *bot-random-state* (make-random-state t))
      (irc-server-connect)
      (loop
	 while (eq *bot-break* nil)
	 do
	   (let ((active-delta (- (get-universal-time) active-time))
		 (stream-data-p (listen *server-stream*)))
	     (cond (stream-data-p
		    (let ((raw-server-msg (irc-server-read *server-stream*)))
		      (cond ((eq (search ":" raw-server-msg) 0)
			     (bot-read raw-server-msg *bot-debug*)
			     (setf active-time (get-universal-time)))
			    ((eq (search "PING :" raw-server-msg) 0) 
			     (irc-ping-reply *server-stream* raw-server-msg active-delta *bot-debug*)
			     (setf active-time (get-universal-time)))
			    (t (format t "UNKNOWN MSG: ~A~%" raw-server-msg)
			       (setf active-time (get-universal-time))))))
		   (t
		    (if (> active-delta *irc-server-timeout*)
			(progn
			  (format t "Timeout: ~A seconds.~%" active-delta)
			  (irc-server-reconnect)))))))
      (when *irc-channel-list*
	(irc-channel-quit *server-stream* *irc-channel-list*))
      (irc-server-quit))))

(defun irc-server-register (server-stream nick user real mode &optional pass)
  (let ((user-params (concatenate 'string user " " mode " * :" real)))
    (when pass (irc-send-cmd server-stream "PASS" pass))
    (irc-send-cmd server-stream "NICK" nick)
    (irc-send-cmd server-stream "USER" user-params)))

(defun irc-auto-chan-join (server-stream &optional channel-list)
  (when channel-list
    (labels ((join-channels (channel-list)
	       (cond ((not (cdr channel-list))
		      (irc-send-cmd server-stream "JOIN" (car channel-list)))
		     (t
		      (irc-send-cmd server-stream "JOIN" (car channel-list))
		      (join-channels (cdr channel-list))))))
      (join-channels channel-list))))

(defun irc-channel-quit (server-stream channel-list)
  (labels ((part-channels (channel-list)
	     (cond ((not (cdr channel-list))
		    (irc-send-cmd server-stream "PART" (car channel-list)))
		   (t
		    (irc-send-cmd server-stream "PART" (car channel-list))
		    (part-channels (cdr channel-list))))))
    (part-channels channel-list)))

(defun irc-send-cmd (server-stream cmd params &optional prefix)
  (if prefix 
      (format server-stream "~A ~A ~A~%" prefix cmd params)
      (format server-stream "~A ~A~%" cmd params))
  (force-output server-stream))

(defun irc-ping-reply (server-stream server-ping active-delta &optional ping-debug)
  (let ((rfc-reply (subseq server-ping 6 (- (length server-ping) 1))))
    (irc-send-cmd server-stream "PONG" rfc-reply)
    (when ping-debug
      (format t "~A [~A seconds]~%" server-ping active-delta)
      (format t "PONG ~A~%" rfc-reply))))

(defun irc-send-privmsg (server-stream target msg)
  (irc-send-cmd server-stream "PRIVMSG" (concatenate 'string target " :" msg)))

(defun bot-read (raw-server-msg &optional bot-debug)
  (let* ((cmd-pos (1+ (search " " raw-server-msg)))
	 (param-pos (+ cmd-pos (1+ (search " " (subseq raw-server-msg cmd-pos)))))
	 (irc-prefix (subseq raw-server-msg 1 (1- cmd-pos)))
	 (irc-cmd (subseq raw-server-msg cmd-pos (1- param-pos)))
	 (irc-msg-tail (subseq raw-server-msg param-pos))
	 (irc-params (subseq irc-msg-tail 0 (1- (length irc-msg-tail))))
	 (numeric-cmd (parse-integer irc-cmd :junk-allowed t))
	 (numeric-cmd-p (integerp numeric-cmd)))
    (cond ((and numeric-cmd-p (> numeric-cmd 400) (< numeric-cmd 600))
	   (irc-err-rpl-handler numeric-cmd irc-prefix irc-cmd irc-params))
	  ((and numeric-cmd-p (> numeric-cmd 0) (< numeric-cmd 400))
	   (irc-info-rpl-handler irc-prefix irc-cmd irc-params))
	  ((equal irc-cmd "NOTICE")
	   (irc-notice-handler irc-prefix irc-cmd irc-params))
	  ((equal irc-cmd "MODE")
	   (irc-mode-handler irc-prefix irc-cmd irc-params))
	  ((equal irc-cmd "JOIN")
	   (irc-join-handler irc-prefix irc-cmd irc-params))
	  ((equal irc-cmd "PRIVMSG")
	   (irc-privmsg-handler irc-prefix irc-params bot-debug))
	  (t
	   (format t "UNKNOWN CMD: :~A ~A ~A~%" irc-prefix irc-cmd irc-params)))
    (when bot-debug
      (format t "DEBUG-RAW: ~A~%" raw-server-msg)
      (format t "DEBUG-READ: prefix: ~A command: ~A parameters: ~A~%" irc-prefix irc-cmd irc-params))))

(defun irc-err-rpl-handler (num prefix cmd params)
  (let* ((server (subseq prefix 0 (1- (length prefix))))
	 (msg-pos (1+ (search " " params)))
	 (msg (subseq params msg-pos)))
    (cond ((equal 433 num)
	   (let* ((failed-pos (1+ (search " " msg)))
		  (failed (subseq msg 0 (1- failed-pos)))
		  (failed-msg (subseq msg failed-pos))
		  (tail-pos (1+ (search " " failed-msg)))
		  (msg-tail (subseq failed-msg tail-pos)))	     
	     (format t "ERROR: ~A [~A] ~A ~A~%" server cmd failed msg-tail)
	     (setf *irc-nick* (concatenate 'string *irc-nick* "`"))))
	  ((equal 451 num)
	   (let ((clean-msg (subseq msg 1)))
	     (format t "ERROR: ~A [~A] ~A~%" server cmd clean-msg)))
	  (t
	   (format t "ERROR-UNKNOWN: ~A [~A] ~A~%" server cmd msg)))))

(defun irc-info-rpl-handler (prefix cmd params)
  (let* ((msg-pos (1+ (search " " params)))
	 (raw-msg (subseq params msg-pos))
	 (msg (if (equal 0 (search ":" raw-msg))
		  (subseq raw-msg 1)
		  raw-msg)))
    (format t "~A [~A] ~A~%" prefix cmd msg)))

(defun irc-notice-handler (prefix cmd params)
    (let* ((msg-pos (1+ (search " " params)))
	   (msg (subseq params (1+ msg-pos))))
      (format t "~A [~A] ~A~%" prefix cmd msg)))

(defun irc-mode-handler (prefix cmd params)
    (let* ((msg-pos (1+ (search " " params)))
	   (user (subseq params 0 (1- msg-pos)))
	   (msg (subseq params (1+ msg-pos))))
      (format t "~A [~A] ~A ~A~%" prefix cmd user msg)))

(defun irc-join-handler (prefix cmd params)
      (format t "~A [~A] ~A~%" prefix cmd params))

(defun irc-privmsg-handler (prefix params &optional privmsg-debug)
  (let* ((src-host (subseq prefix (1+ (search "@" prefix))))
	 (src-nick (subseq prefix 0 (search "!" prefix)))
	 (src-target (subseq params 0 (search " " params)))
	 (target (if (equal src-target *irc-nick*)
		      src-nick
		      src-target))
	 (src-msg (subseq params (1+ (search ":" params))))
	 (bot-cmd-p (if (equal 0 (search "," src-msg))
			t))
	 (bot-params-p (if (and bot-cmd-p (search " " src-msg))
			       t))
	 (bot-cmd (cond ((and bot-cmd-p bot-params-p)
			 (subseq src-msg 1 (search " " src-msg)))
			(bot-cmd-p
			 (subseq src-msg 1))))
	 (bot-params (if bot-params-p
			 (subseq src-msg (1+ (search " " src-msg))))))
    (if (bot-abuse-prevention src-nick src-msg target)
	(cond (bot-cmd-p
	       (if (member (intern (string-upcase bot-cmd)) *bot-cmds*)
		   (funcall (read-from-string (concatenate 'string "bot-cmd-" bot-cmd))
			    *server-stream*
			    src-host
			    src-nick
			    target
			    bot-params)
		   (irc-send-privmsg *server-stream*
				     target
				     (concatenate 'string
						  bot-cmd
						  "?! What the hell you talking about, "
						  src-nick
						  "?"))))
	      ((equal src-msg (concatenate 'string *irc-nick* "!"))
	       (irc-send-privmsg *server-stream*
				 target
				 (concatenate 'string src-nick "!")))
	      (t
	       ;; extraneous text processing here
	       nil)))
    (when privmsg-debug
      (format t "DEBUG-PRIVMSG: src-host: ~A src-nick: ~A target: ~A src-msg: ~A bot-cmd: ~A bot-params: ~A~%"
	      src-host src-nick target src-msg bot-cmd bot-params))))

(defun bot-abuse-prevention (nick msg target)
  (let ((input (concatenate 'string nick "+" msg))
	(nick-pen-box (cdr (assoc nick *abuse-pen-box* :test 'equal))))
    (setf *abuse-cur-input* input)
    (setf *abuse-cur-time* (get-universal-time))
    (if (and (<= (- *abuse-cur-time* *abuse-prv-time*) 5) (equal *abuse-cur-input* *abuse-prv-input*))
	(incf *abuse-flood-flag*)
	(setf *abuse-flood-flag* 0))
    (if (and nick-pen-box (< (- (get-universal-time) nick-pen-box) 45))
	nil
	(cond ((>= *abuse-flood-flag* 4)
	       (irc-send-privmsg *server-stream* target (concatenate 'string "piss off " nick "!"))
	       (push (cons nick (get-universal-time)) *abuse-pen-box*)
	       nil)
	      (t
	       (if (and (car *abuse-pen-box*) (> (- (get-universal-time) (cdr (car *abuse-pen-box*))) 45))
		   (pop *abuse-pen-box*))
	       (setf *abuse-prv-input* *abuse-cur-input*)
	       (setf *abuse-prv-time* *abuse-cur-time*))))))

;; cmd-args is (src-host src-nick target bot-params) as defined by irc-privmsg-handler

(defun bot-cmd-sheep? (server-stream &rest cmd-args)
  (let ((judgement (random 2))
	(nick (nth 1 cmd-args))
	(target (nth 2 cmd-args)))
    (if (equal judgement 1)
	(irc-send-privmsg server-stream target (concatenate 'string nick " is a sheep!"))
	(irc-send-privmsg server-stream target (concatenate 'string nick " is a heathen!")))))

(defun bot-cmd-piss-off (server-stream &rest cmd-args)
  (let ((host (nth 0 cmd-args))
	(nick (nth 1 cmd-args))
	(target (nth 2 cmd-args)))
    (if (equal *bot-owner* (concatenate 'string nick "@" host))
	(setf *bot-break* t)
	(irc-send-privmsg server-stream target (concatenate 'string nick ", you piss off!")))))

(defun bot-cmd-master (server-stream &rest cmd-args)
  (let ((host (nth 0 cmd-args))
	(nick (nth 1 cmd-args))
	(target (nth 2 cmd-args)))
    (cond ((eq *bot-owner* nil)
	   (setf *bot-owner* (concatenate 'string nick "@" host))
	   (irc-send-privmsg server-stream target (concatenate 'string nick ", my liege!")))
	  (t (irc-send-privmsg server-stream target (concatenate 'string nick ", I follow only " *bot-owner*))))))

(defun bot-cmd-soul (server-stream &rest cmd-args)
  (let ((host (nth 0 cmd-args))
	(nick (nth 1 cmd-args))
	(target (nth 2 cmd-args)))
    (irc-send-privmsg server-stream target (concatenate 'string
							nick
							", all is revealed at "
							*bot-repo*))))

(defun bot-cmd-cancel (server-stream &rest cmd-args)
  (let ((host (nth 0 cmd-args))
	(nick (nth 1 cmd-args))
	(target (nth 2 cmd-args)))
    (if (and (< (- (get-universal-time) *r-timer*) *r-timeout*)
	     (or (equal (concatenate 'string nick "@" host)
		     *bot-owner*)
		 (equal nick *r-challenger*)))
	(progn
	  (irc-send-privmsg server-stream target
			    (concatenate 'string
					 *r-challenger*
					 " has been judged a sheep!"
					 " The challenge has been cancelled!"))
	  (setf *r-timer* (- (get-universal-time) (+ *r-timeout* 10)))
	  (setf *r-challenger* "")
	  (setf *r-challenged* "")))))

(defun roulette (server-stream target first second)
  (let ((chamber (random *r-chamber*))
	(step 0)
	(shot nil))
    (loop
       while (eq shot nil)
       do
	 (let ((player first)
	       (wait (+ (random 3) 1)))
	   (cond ((equal chamber step)
		  (sleep 1)
		  (irc-send-privmsg server-stream target
				    (concatenate 'string
						 "..."))
		  (sleep wait)
		  (irc-send-privmsg server-stream target
				    (concatenate 'string
						 "BLAMMO!! "
						 player
						 " falls to the floor lifeless."))
		  (setf *r-timer* (- (get-universal-time) (+ *r-timeout* 10)))
		  (setf *r-challenger* "")
		  (setf *r-challenged* "")
		  (setf shot t))
		 (t
		  (sleep 1)
		  (irc-send-privmsg server-stream target
				    (concatenate 'string
						 "..."))
		  (sleep wait)
		  (irc-send-privmsg server-stream target
				    (concatenate 'string
						 "CLICK!!"))
		  (sleep 1)		   			 
		  (irc-send-privmsg server-stream target
				    (concatenate 'string
						 player
						 " sweats profusely and drops"
						 " the gun"))
		  (setf first second)
		  (setf second player)
		  (setf step (+ 1 step))
		  (sleep 2)
		  (irc-send-privmsg server-stream target
				    (concatenate 'string
						 first
						 " picks up gun, "
						 "brings it to "
						 "their head and then"))))))))

(defun bot-cmd-r (server-stream &rest cmd-args)
  (let ((nick (nth 1 cmd-args))
	(target (nth 2 cmd-args))
	(challenged (nth 3 cmd-args)))
    (cond ((equal nick challenged)
	   (irc-send-privmsg server-stream target
			     (concatenate 'string
					  "Sorry "
					  nick
					  ", seppuku is not allowed.")))
	  ((equal *irc-nick* challenged)
	   (irc-send-privmsg server-stream target
			     (concatenate 'string
					  "Sorry "
					  nick
					  ", this round is rigged. "
					  *irc-nick*
					  " points the gun at "
					  nick
					  ". BLAMMO!! A good bot never leaves "
					  "their own existance to chance!")))
	  ((< (- (get-universal-time) *r-timer*) *r-timeout*)
	   (irc-send-privmsg server-stream target
			     (concatenate 'string
					  "There is a standing offer for roulette. "
					  *r-challenger*
					  " is waiting for "
					  *r-challenged*
					  "'s timid response!")))
	  (t
	   (setf *r-challenger* nick)
	   (setf *r-challenged* challenged)
	   (setf *r-timer* (get-universal-time))
	   (irc-send-privmsg server-stream target
			     (concatenate 'string
					  *r-challenger*
					  " has challenged "
					  *r-challenged*
					  " to a game of russian roulette! Will "
					  *r-challenged*
					  " step up to "
					  *r-challenger*
					  "'s bravado?!?!"))))))

(defun bot-cmd-accept (server-stream &rest cmd-args)
  (let ((nick (nth 1 cmd-args))
	(target (nth 2 cmd-args))
	(turn (random 2)))
    (cond ((> (- (get-universal-time) *r-timer*) *r-timeout*)
	   (irc-send-privmsg server-stream target
			     (concatenate 'string
					  nick
					  ", you dolt! No one has challenged "
					  "you or you previously ran off "
					  "chicken!")))
	  ((not (equal *r-challenged* nick))
	   (irc-send-privmsg server-stream target
			     (concatenate 'string
					  "Back off "
					  nick
					  "! "
					  *r-challenger*
					  " has not challenged you...yet!")))
	  (t
	   (irc-send-privmsg server-stream target
			     (concatenate 'string
					  "An innocent bystander checks the gun, lays "
					  "it on the table and gives it a spin!"))
	   (if (equal turn 1)
	       (progn
		 (irc-send-privmsg server-stream target
				   (concatenate 'string
						"The gun points to >>> "
						*r-challenged*
						" <<< ! "))
		 (irc-send-privmsg server-stream target
				   (concatenate 'string
						"They pick up the gun and "
						"bring it to their head "
						"and then"))
		 (roulette server-stream target *r-challenged* *r-challenger*))
	       (progn
		 (irc-send-privmsg server-stream target
				   (concatenate 'string
						"The gun points to >>> "
						*r-challenger*
						" <<< ! "))
		 (irc-send-privmsg server-stream target
				   (concatenate 'string
						"They pick up the gun and "
						"bring it to their head "
						"and then"))
		 (roulette server-stream target *r-challenger* *r-challenged*)))
	   (setf *r-timer* (- (get-universal-time) (+ *r-timeout* 10)))))))

(defun bot-cmd-no (server-stream &rest cmd-args)
  (let ((nick (nth 1 cmd-args))
	(target (nth 2 cmd-args)))
    (cond ((or (> (- (get-universal-time) *r-timer*) *r-timeout*)
	       (not (equal *r-challenged* nick)))
	   (irc-send-privmsg server-stream target
			     (concatenate 'string
					  "no?! What the hell you talking about, "
					  nick
					  "?")))
	  (t
	   (irc-send-privmsg server-stream target
			     (concatenate 'string
					  nick
					  " is all nerves. "
					  nick
					  " urinates and then leaves the fight with"
					  " nothing more than stained pants!"))
	   (setf *r-timer* (- (get-universal-time) (+ *r-timeout* 10)))))))
