
;; title: Open-Legal-Aid-DAO
;; version: 1.0.0
;; summary: Decentralized Legal Aid DAO for funding social justice cases
;; description: A donation pool governed by DAO voting to fund legal cases for underrepresented groups

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-insufficient-funds (err u103))
(define-constant err-invalid-amount (err u104))
(define-constant err-case-not-active (err u105))
(define-constant err-already-voted (err u106))
(define-constant err-not-authorized (err u107))
(define-constant err-voting-period-ended (err u108))
(define-constant err-case-not-funded (err u109))
(define-constant err-payment-already-made (err u110))
(define-constant err-milestone-not-found (err u111))
(define-constant err-milestone-already-completed (err u112))
(define-constant err-invalid-milestone (err u113))

(define-constant min-donation u1000000)
(define-constant voting-period u144)
(define-constant quorum-threshold u3)

(define-data-var next-case-id uint u1)
(define-data-var total-donations uint u0)
(define-data-var dao-treasury uint u0)
(define-data-var next-milestone-id uint u1)

(define-map cases uint {
  title: (string-ascii 100),
  description: (string-ascii 500),
  requested-amount: uint,
  lawyer-address: principal,
  submitter: principal,
  votes-for: uint,
  votes-against: uint,
  status: (string-ascii 20),
  created-at: uint,
  funded-at: (optional uint),
  payment-made: bool
})

(define-map case-voters {case-id: uint, voter: principal} bool)
(define-map donor-contributions principal uint)
(define-map lawyer-registrations principal {
  name: (string-ascii 100),
  specialty: (string-ascii 100),
  cases-handled: uint,
  reputation-score: uint
})

(define-map milestones uint {
  case-id: uint,
  description: (string-ascii 200),
  amount: uint,
  votes-for: uint,
  votes-against: uint,
  status: (string-ascii 20),
  created-at: uint,
  completed-at: (optional uint)
})

(define-map milestone-voters {milestone-id: uint, voter: principal} bool)
(define-map case-milestones {case-id: uint, milestone-index: uint} uint)

(define-public (donate (amount uint))
  (begin
    (asserts! (>= amount min-donation) err-invalid-amount)
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set total-donations (+ (var-get total-donations) amount))
    (var-set dao-treasury (+ (var-get dao-treasury) amount))
    (map-set donor-contributions tx-sender 
      (+ (default-to u0 (map-get? donor-contributions tx-sender)) amount))
    (ok amount)
  )
)

(define-public (register-lawyer (name (string-ascii 100)) (specialty (string-ascii 100)))
  (begin
    (asserts! (is-none (map-get? lawyer-registrations tx-sender)) err-already-exists)
    (map-set lawyer-registrations tx-sender {
      name: name,
      specialty: specialty,
      cases-handled: u0,
      reputation-score: u100
    })
    (ok true)
  )
)

(define-public (submit-case (title (string-ascii 100)) 
                          (description (string-ascii 500)) 
                          (requested-amount uint) 
                          (lawyer-address principal))
  (let ((case-id (var-get next-case-id)))
    (begin
      (asserts! (> requested-amount u0) err-invalid-amount)
      (asserts! (is-some (map-get? lawyer-registrations lawyer-address)) err-not-found)
      (asserts! (<= requested-amount (var-get dao-treasury)) err-insufficient-funds)
      (map-set cases case-id {
        title: title,
        description: description,
        requested-amount: requested-amount,
        lawyer-address: lawyer-address,
        submitter: tx-sender,
        votes-for: u0,
        votes-against: u0,
        status: "pending",
        created-at: stacks-block-height,
        funded-at: none,
        payment-made: false
      })
      (var-set next-case-id (+ case-id u1))
      (ok case-id)
    )
  )
)

(define-public (vote-on-case (case-id uint) (vote-for bool))
  (let ((case-data (unwrap! (map-get? cases case-id) err-not-found))
        (voter-key {case-id: case-id, voter: tx-sender}))
    (begin
      (asserts! (is-eq (get status case-data) "pending") err-case-not-active)
      (asserts! (< (- stacks-block-height (get created-at case-data)) voting-period) err-voting-period-ended)
      (asserts! (is-none (map-get? case-voters voter-key)) err-already-voted)
      (asserts! (> (default-to u0 (map-get? donor-contributions tx-sender)) u0) err-not-authorized)
      (map-set case-voters voter-key true)
      (map-set cases case-id 
        (merge case-data {
          votes-for: (if vote-for (+ (get votes-for case-data) u1) (get votes-for case-data)),
          votes-against: (if vote-for (get votes-against case-data) (+ (get votes-against case-data) u1))
        }))
      (ok true)
    )
  )
)

(define-public (finalize-case (case-id uint))
  (let ((case-data (unwrap! (map-get? cases case-id) err-not-found)))
    (begin
      (asserts! (is-eq (get status case-data) "pending") err-case-not-active)
      (asserts! (>= (- stacks-block-height (get created-at case-data)) voting-period) err-voting-period-ended)
      (asserts! (>= (+ (get votes-for case-data) (get votes-against case-data)) quorum-threshold) err-insufficient-funds)
      (if (> (get votes-for case-data) (get votes-against case-data))
        (begin
          (map-set cases case-id (merge case-data {
            status: "approved",
            funded-at: (some stacks-block-height)
          }))
          (ok "approved")
        )
        (begin
          (map-set cases case-id (merge case-data {status: "rejected"}))
          (ok "rejected")
        )
      )
    )
  )
)

(define-public (release-payment (case-id uint))
  (let ((case-data (unwrap! (map-get? cases case-id) err-not-found)))
    (begin
      (asserts! (is-eq (get status case-data) "approved") err-case-not-funded)
      (asserts! (not (get payment-made case-data)) err-payment-already-made)
      (asserts! (or (is-eq tx-sender (get submitter case-data)) 
                   (is-eq tx-sender contract-owner)) err-not-authorized)
      (try! (as-contract (stx-transfer? (get requested-amount case-data) 
                                      tx-sender 
                                      (get lawyer-address case-data))))
      (var-set dao-treasury (- (var-get dao-treasury) (get requested-amount case-data)))
      (map-set cases case-id (merge case-data {
        status: "completed",
        payment-made: true
      }))
      (try! (update-lawyer-stats (get lawyer-address case-data)))
      (ok (get requested-amount case-data))
    )
  )
)

(define-public (emergency-withdraw (amount uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= amount (var-get dao-treasury)) err-insufficient-funds)
    (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
    (var-set dao-treasury (- (var-get dao-treasury) amount))
    (ok amount)
  )
)

(define-private (update-lawyer-stats (lawyer principal))
  (let ((lawyer-data (unwrap! (map-get? lawyer-registrations lawyer) err-not-found)))
    (begin
      (map-set lawyer-registrations lawyer 
        (merge lawyer-data {
          cases-handled: (+ (get cases-handled lawyer-data) u1),
          reputation-score: (+ (get reputation-score lawyer-data) u10)
        }))
      (ok true)
    )
  )
)

(define-read-only (get-case (case-id uint))
  (map-get? cases case-id)
)

(define-read-only (get-lawyer-info (lawyer principal))
  (map-get? lawyer-registrations lawyer)
)

(define-read-only (get-donor-contribution (donor principal))
  (default-to u0 (map-get? donor-contributions donor))
)

(define-read-only (get-dao-stats)
  {
    total-donations: (var-get total-donations),
    dao-treasury: (var-get dao-treasury),
    next-case-id: (var-get next-case-id),
    total-cases: (- (var-get next-case-id) u1)
  }
)

(define-read-only (has-voted (case-id uint) (voter principal))
  (is-some (map-get? case-voters {case-id: case-id, voter: voter}))
)

(define-read-only (get-voting-status (case-id uint))
  (match (map-get? cases case-id)
    case-data {
      votes-for: (get votes-for case-data),
      votes-against: (get votes-against case-data),
      voting-ends-at: (+ (get created-at case-data) voting-period),
      current-block: stacks-block-height,
      is-active: (and (is-eq (get status case-data) "pending")
                     (< (- stacks-block-height (get created-at case-data)) voting-period))
    }
    {
      votes-for: u0,
      votes-against: u0,
      voting-ends-at: u0,
      current-block: stacks-block-height,
      is-active: false
    }
  )
)

(define-public (create-milestone (case-id uint) (description (string-ascii 200)) (amount uint) (milestone-index uint))
  (let ((milestone-id (var-get next-milestone-id))
        (case-data (unwrap! (map-get? cases case-id) err-not-found)))
    (begin
      (asserts! (is-eq tx-sender (get submitter case-data)) err-not-authorized)
      (asserts! (is-eq (get status case-data) "approved") err-case-not-active)
      (asserts! (> amount u0) err-invalid-amount)
      (asserts! (<= amount (get requested-amount case-data)) err-invalid-amount)
      (map-set milestones milestone-id {
        case-id: case-id,
        description: description,
        amount: amount,
        votes-for: u0,
        votes-against: u0,
        status: "pending",
        created-at: stacks-block-height,
        completed-at: none
      })
      (map-set case-milestones {case-id: case-id, milestone-index: milestone-index} milestone-id)
      (var-set next-milestone-id (+ milestone-id u1))
      (ok milestone-id)
    )
  )
)

(define-public (vote-on-milestone (milestone-id uint) (vote-for bool))
  (let ((milestone-data (unwrap! (map-get? milestones milestone-id) err-milestone-not-found))
        (voter-key {milestone-id: milestone-id, voter: tx-sender}))
    (begin
      (asserts! (is-eq (get status milestone-data) "pending") err-milestone-already-completed)
      (asserts! (is-none (map-get? milestone-voters voter-key)) err-already-voted)
      (asserts! (> (default-to u0 (map-get? donor-contributions tx-sender)) u0) err-not-authorized)
      (map-set milestone-voters voter-key true)
      (map-set milestones milestone-id
        (merge milestone-data {
          votes-for: (if vote-for (+ (get votes-for milestone-data) u1) (get votes-for milestone-data)),
          votes-against: (if vote-for (get votes-against milestone-data) (+ (get votes-against milestone-data) u1))
        }))
      (ok true)
    )
  )
)

(define-public (finalize-milestone (milestone-id uint))
  (let ((milestone-data (unwrap! (map-get? milestones milestone-id) err-milestone-not-found))
        (case-data (unwrap! (map-get? cases (get case-id milestone-data)) err-not-found)))
    (begin
      (asserts! (is-eq (get status milestone-data) "pending") err-milestone-already-completed)
      (asserts! (>= (+ (get votes-for milestone-data) (get votes-against milestone-data)) quorum-threshold) err-insufficient-funds)
      (if (> (get votes-for milestone-data) (get votes-against milestone-data))
        (begin
          (map-set milestones milestone-id (merge milestone-data {
            status: "approved",
            completed-at: (some stacks-block-height)
          }))
          (ok "approved")
        )
        (begin
          (map-set milestones milestone-id (merge milestone-data {status: "rejected"}))
          (ok "rejected")
        )
      )
    )
  )
)

(define-public (release-milestone-payment (milestone-id uint))
  (let ((milestone-data (unwrap! (map-get? milestones milestone-id) err-milestone-not-found))
        (case-data (unwrap! (map-get? cases (get case-id milestone-data)) err-not-found)))
    (begin
      (asserts! (is-eq (get status milestone-data) "approved") err-milestone-not-found)
      (asserts! (or (is-eq tx-sender (get submitter case-data))
                   (is-eq tx-sender contract-owner)) err-not-authorized)
      (try! (as-contract (stx-transfer? (get amount milestone-data)
                                      tx-sender
                                      (get lawyer-address case-data))))
      (var-set dao-treasury (- (var-get dao-treasury) (get amount milestone-data)))
      (map-set milestones milestone-id (merge milestone-data {
        status: "completed"
      }))
      (ok (get amount milestone-data))
    )
  )
)

(define-read-only (get-milestone (milestone-id uint))
  (map-get? milestones milestone-id)
)

(define-read-only (get-case-milestone (case-id uint) (milestone-index uint))
  (map-get? case-milestones {case-id: case-id, milestone-index: milestone-index})
)

(define-read-only (has-voted-on-milestone (milestone-id uint) (voter principal))
  (is-some (map-get? milestone-voters {milestone-id: milestone-id, voter: voter}))
)

