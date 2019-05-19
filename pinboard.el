;;; pinboard.el --- pinboard.in client -*- lexical-binding: t -*-
;; Copyright 2019 by Dave Pearson <davep@davep.org>

;; Author: Dave Pearson <davep@davep.org>
;; Version: 0.1
;; Keywords: hypermedia, bookmarking, reading, pinboard
;; URL: https://github.com/davep/pinboard.el
;; Package-Requires: ((emacs "25"))

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
;; Public License for more details.
;;
;; You should have received a copy of the GNU General Public License along
;; with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; pinboard.el provides a simple client for pinboard.in.

;;; Code:

(require 'seq)
(require 'json)
(require 'url-vars)
(require 'browse-url)

(defgroup pinboard nil
  "Pinboard client for Emacs."
  :group 'hypermedia)

(defcustom pinboard-private-symbol "\u2022"
  "The character to use to show a pin is private."
  :type 'string
  :group 'pinboard)

(defcustom pinboard-public-symbol "\u25e6"
  "The character to use to show a pin is public."
  :type 'string
  :group 'pinboard)

(defconst pinboard-api-url "https://api.pinboard.in/v1/%s?auth_token=%s&format=json"
  "Base URL of the Pinboard API.")

(defconst pinboard-agent "pinboard.el (https://github/davep/pinboard.el)"
  "User agent to send to the Pinboard server.")

(defvar pinboard-api-token nil
  "Your Pinboard account's API token.

Visit https://pinboard.in/settings/password to get the token for
your account.

DO NOT EVER SET THIS IN A WAY THAT IT CAN BE SEEN IN SOME PUBLIC
REPOSITORY!")

(defvar pinboard-pins nil
  "Cache of pins to display.")

(defvar pinboard-tags nil
  "Cache of tags the user has used.")

(defun pinboard-last-called (caller)
  "When was CALLER last called?"
  (or (get caller 'pinboard-last-called) 0))

(defun pinboard-too-soon (caller rate)
  "Are we hitting on Pinboard too soon?

See if we're calling CALLER before RATE has expired."
  (let ((last (pinboard-last-called caller)))
    (when last
      (<= (- (float-time) last) rate))))

(defun pinboard-api-url (&rest params)
  "Build the API call from PARAMS."
  (format pinboard-api-url (string-join params "/") pinboard-api-token))

(defun pinboard-call (url caller)
  "Call on URL and return the data.

CALLER is a symbol that is the name of the caller. This is used
to help set rate limits."
  (let ((url-request-extra-headers `(("User-Agent" . ,pinboard-agent)))
        (url-show-status nil))
    (put caller 'pinboard-last-called (float-time))
    (with-temp-buffer
      (url-insert-file-contents url)
      (json-read-from-string (buffer-string)))))

(defun pinboard-last-updated ()
  "Get when Pinboard was last updated."
  (let ((result (alist-get 'update_time (pinboard-call (pinboard-api-url "posts" "update") 'pinboard-last-updated))))
    (when result
      (float-time (decode-time (parse-iso8601-time-string result))))))

(defun pinboard-get-tags ()
  "Get the list of tags used by the user."
  ;; If it's within the 3 second rule...
  (if (pinboard-too-soon 'pinboard-get-tags 3)
      ;; ...just go with what we've got.
      pinboard-tags
    ;; We're not calling on Pinboard too soon. So, next up, let's see if
    ;; pins have been updated since we last called for tags, or if we simply
    ;; don't have any tags yet...
    (if (or (not pinboard-tags) (< (pinboard-last-called 'pinboard-get-tags) (pinboard-last-updated)))
        ;; ...grab a copy of the user's tags.
        (setq pinboard-tags
              (pinboard-call
               (pinboard-api-url "tags" "get")
               'pinboard-tags))
      ;; Looks like nothing has changed, so go with the tags we've already
      ;; got.
      pinboard-tags)))

(defun pinboard-all-posts ()
  "Return all of the user's posts on Pinboard."
  ;; If we're calling on the list within 5 minutes of a previous call, just
  ;; go with what we've got (see the rate limits in the Pinboard API).
  (if (pinboard-too-soon 'pinboard-all-posts 300)
      pinboard-pins
    ;; Okay, we're not calling too soon. This also suggests we've called
    ;; before too. If we don't have any pins yet (normally not an issue at
    ;; this point, but useful for testing), or pins have been updated more
    ;; recently...
    (if (or (not pinboard-pins) (< (pinboard-last-called 'pinboard-all-posts) (pinboard-last-updated)))
        ;; ...grab a fresh copy.
        (setq pinboard-pins
              (pinboard-call
               (pinboard-api-url "posts" "all")
               'pinboard-all-posts))
      ;; Looks like nothing has changed. Return what we've got.
      pinboard-pins)))

(defun pinboard-find-pin (hash)
  "Find and return the pin identified by HASH."
  (seq-find
   (lambda (pin)
     (string= (alist-get 'hash pin) hash))
   pinboard-pins))

(defun pinboard-redraw (&optional filter)
  "Redraw the pin list.

Optionally filter the list of pins to draw using the function
FILTER."
  (setq tabulated-list-entries
        (mapcar (lambda (pin)
                  (list
                   (alist-get 'hash pin)
                   (vector
                    (if (string= (alist-get 'shared pin) "yes")
                        pinboard-public-symbol
                      pinboard-private-symbol)
                    (alist-get 'description pin)
                    (alist-get 'href pin))))
                (seq-filter (or filter #'identity) pinboard-pins)))
  (tabulated-list-print t))

(defun pinboard-open ()
  "Open the currently-highlighted pin in a web browser."
  (interactive)
  (let ((pin (pinboard-find-pin (tabulated-list-get-id))))
    (if pin
        (browse-url (alist-get 'href pin))
      (error "Could not find pin %s" (tabulated-list-get-id)))))

(defun pinboard-view ()
  "View the details of the currently-highlighted pin."
  (interactive)
  (let ((pin (pinboard-find-pin (tabulated-list-get-id))))
    (unless pin
      (error "Could not find pin %s" (tabulated-list-get-id)))
    ;; TODO: For now, this is just a dump of pin data to a help window. This
    ;; will be done a lot better if it's a nicely-formatted display.
    (with-help-window "*Pinboard pin*"
      (mapc (lambda (info)
              (princ (format "%s:\n%s\n\n" (car info) (cdr info))))
            pin))))

(defun pinboard-unread ()
  "Only show unread pins."
  (interactive)
  (pinboard-redraw (lambda (pin) (string= (alist-get 'toread pin) "yes"))))

(defun pinboard-public ()
  "Only show public pins."
  (interactive)
  (pinboard-redraw (lambda (pin) (string= (alist-get 'shared pin) "yes"))))

(defun pinboard-private ()
  "Only show private pins."
  (interactive)
  (pinboard-redraw (lambda (pin) (string= (alist-get 'shared pin) "no"))))

(defun pinboard-tagged (tag)
  "Only show pins that are tagged with TAG."
  (interactive (list (completing-read "Tag: " (pinboard-get-tags))))
  (pinboard-redraw
   (lambda (pin)
     (seq-contains (split-string (alist-get 'tags pin)) tag))))

(defun pinboard-refresh ()
  "Refresh the list."
  (interactive)
  (pinboard-all-posts)
  (pinboard-redraw))

(defvar pinboard-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    (define-key map "g"         #'pinboard-refresh)
    (define-key map "p"         #'pinboard-public)
    (define-key map "P"         #'pinboard-private)
    (define-key map "u"         #'pinboard-unread)
    (define-key map "t"         #'pinboard-tagged)
    (define-key map " "         #'pinboard-view)
    (define-key map (kbd "RET") #'pinboard-open)
    map)
  "Local keymap for `pinboard'.")

(define-derived-mode pinboard-mode tabulated-list-mode "Pinboard Mode"
  "Major mode for handling a list of Pinboard pins."
  (setq tabulated-list-format
        [("P" 1 t)
         ("Description" 60 t)
         ("URL" 30 t)])
  (tabulated-list-init-header))

;;;###autoload
(defun pinboard ()
  "Browse your Pinboard pins."
  (interactive)
  (if (not pinboard-api-token)
      ;; TODO: Have some sensible method of recording/loading the token, in
      ;; a way that heavily-discourages the user from placing it where
      ;; someone could see it.
      (error "Please set your Pinboard API token")
    (pop-to-buffer "*Pinboard*")
    (pinboard-mode)
    (pinboard-refresh)))

(provide 'pinboard)

;;; pinboard.el ends here
