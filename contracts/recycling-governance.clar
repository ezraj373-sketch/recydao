;; Recycling Governance - DAO governance for community recycling initiatives
;; Handles member management, rewards, and governance operations

;; Constants
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-MEMBER-NOT-FOUND (err u201))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u202))
(define-constant ERR-ALREADY-MEMBER (err u203))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u204))
(define-constant ERR-INVALID-REWARD-CLAIM (err u205))
(define-constant ERR-REWARD-ALREADY-CLAIMED (err u206))
(define-constant ERR-INVALID-GOVERNANCE-ACTION (err u207))

(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-REPUTATION-THRESHOLD u50)
(define-constant GOVERNANCE-TOKEN-SUPPLY u1000000)
(define-constant PROPOSAL-VOTING_PERIOD u288) ;; ~2 days in blocks
(define-constant MIN-VOTING-POWER u10)

;; Data Variables
(define-data-var total-members uint u0)
(define-data-var governance-proposal-counter uint u1)
(define-data-var total-tokens-distributed uint u0)
(define-data-var reward-pool-balance uint u0)

;; Data Maps

;; DAO member registry with governance rights
(define-map members
  principal
  {
    join-date: uint,
    reputation-score: uint,
    governance-tokens: uint,
    projects-proposed: uint,
    votes-cast: uint,
    member-tier: (string-ascii 15), ;; "bronze", "silver", "gold", "moderator"
    active: bool,
    last-activity: uint
  }
)

;; Governance proposals for DAO operations
(define-map governance-proposals
  uint ;; proposal-id
  {
    proposer: principal,
    proposal-type: (string-ascii 20), ;; "parameter", "treasury", "member-action"
    title: (string-ascii 100),
    description: (string-ascii 300),
    target-member: (optional principal),
    parameter-change: (optional (string-ascii 50)),
    new-value: (optional uint),
    treasury-amount: (optional uint),
    creation-time: uint,
    voting-deadline: uint,
    status: (string-ascii 15), ;; "active", "passed", "rejected", "executed"
    votes-for: uint,
    votes-against: uint,
    total-voting-power: uint
  }
)

;; Governance voting records
(define-map governance-votes
  { proposal-id: uint, voter: principal }
  {
    vote: bool,
    voting-power: uint,
    vote-time: uint
  }
)

;; Reward claim tracking
(define-map reward-claims
  { member: principal, reward-type: (string-ascii 20) }
  {
    amount: uint,
    claim-time: uint,
    claim-period: uint
  }
)

;; Member reputation history
(define-map reputation-changes
  { member: principal, change-id: uint }
  {
    previous-score: uint,
    new-score: uint,
    change-reason: (string-ascii 50),
    change-time: uint,
    changed-by: principal
  }
)

;; Token distribution tracking
(define-map token-distributions
  uint ;; distribution-id
  {
    recipient: principal,
    amount: uint,
    distribution-type: (string-ascii 30), ;; "contribution", "proposal", "voting", "impact"
    distribution-time: uint,
    related-project: (optional uint)
  }
)

;; Private Functions

;; Generate next governance proposal ID
(define-private (get-next-governance-proposal-id)
  (let ((current-id (var-get governance-proposal-counter)))
    (var-set governance-proposal-counter (+ current-id u1))
    current-id
  )
)

;; Calculate member voting power based on reputation and tokens
(define-private (calculate-voting-power (member principal))
  (let ((member-data (map-get? members member)))
    (if (is-some member-data)
        (let ((member-info (unwrap-panic member-data)))
          (if (get active member-info)
              (+ (/ (get reputation-score member-info) u10) (get governance-tokens member-info))
              u0
          )
        )
        u0
    )
  )
)

;; Determine member tier based on reputation and activity
(define-private (calculate-member-tier (reputation uint) (projects uint) (votes uint))
  (if (>= reputation u200)
      "gold"
      (if (>= reputation u100)
          "silver"
          "bronze"
      )
  )
)

;; Check if member can create governance proposals
(define-private (can-create-proposal (member principal))
  (let ((member-data (map-get? members member)))
    (if (is-some member-data)
        (let ((member-info (unwrap-panic member-data)))
          (and (get active member-info)
               (>= (get reputation-score member-info) MIN-REPUTATION-THRESHOLD)
          )
        )
        false
    )
  )
)

;; Public Functions

;; Register as DAO member
(define-public (join-dao)
  (begin
    (asserts! (is-none (map-get? members tx-sender)) ERR-ALREADY-MEMBER)
    
    (map-set members tx-sender {
      join-date: burn-block-height,
      reputation-score: u50, ;; Starting reputation
      governance-tokens: u0,
      projects-proposed: u0,
      votes-cast: u0,
      member-tier: "bronze",
      active: true,
      last-activity: burn-block-height
    })
    
    (var-set total-members (+ (var-get total-members) u1))
    
    (ok true)
  )
)

;; Distribute governance tokens for contributions
(define-public (distribute-tokens (recipient principal) (amount uint) (distribution-type (string-ascii 30)) (related-project (optional uint)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED) ;; For now, only owner can distribute
    (asserts! (is-some (map-get? members recipient)) ERR-MEMBER-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-REWARD-CLAIM)
    
    ;; Update member token balance
    (let ((member-data (unwrap-panic (map-get? members recipient))))
      (map-set members recipient (merge member-data {
        governance-tokens: (+ (get governance-tokens member-data) amount),
        last-activity: burn-block-height
      }))
    )
    
    ;; Record distribution
    (let ((distribution-id (var-get total-tokens-distributed)))
      (map-set token-distributions distribution-id {
        recipient: recipient,
        amount: amount,
        distribution-type: distribution-type,
        distribution-time: burn-block-height,
        related-project: related-project
      })
    )
    
    (var-set total-tokens-distributed (+ (var-get total-tokens-distributed) amount))
    
    (ok amount)
  )
)

;; Update member reputation
(define-public (update-reputation (member principal) (new-score uint) (reason (string-ascii 50)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? members member)) ERR-MEMBER-NOT-FOUND)
    
    (let ((member-data (unwrap-panic (map-get? members member)))
          (old-score (get reputation-score (unwrap-panic (map-get? members member)))))
      
      ;; Update member reputation and tier
      (let ((new-tier (calculate-member-tier new-score (get projects-proposed member-data) (get votes-cast member-data))))
        (map-set members member (merge member-data {
          reputation-score: new-score,
          member-tier: new-tier,
          last-activity: burn-block-height
        }))
      )
      
      ;; Record reputation change
      (let ((change-id (get votes-cast member-data))) ;; Using votes-cast as change-id for simplicity
        (map-set reputation-changes { member: member, change-id: change-id } {
          previous-score: old-score,
          new-score: new-score,
          change-reason: reason,
          change-time: burn-block-height,
          changed-by: tx-sender
        })
      )
      
      (ok true)
    )
  )
)

;; Create governance proposal
(define-public (create-governance-proposal 
  (proposal-type (string-ascii 20))
  (title (string-ascii 100))
  (description (string-ascii 300))
  (target-member (optional principal))
  (parameter-change (optional (string-ascii 50)))
  (new-value (optional uint))
  (treasury-amount (optional uint))
)
  (begin
    (asserts! (can-create-proposal tx-sender) ERR-INSUFFICIENT-REPUTATION)
    (asserts! (> (len title) u0) ERR-INVALID-GOVERNANCE-ACTION)
    
    (let ((proposal-id (get-next-governance-proposal-id))
          (voting-deadline (+ burn-block-height PROPOSAL-VOTING_PERIOD)))
      
      (map-set governance-proposals proposal-id {
        proposer: tx-sender,
        proposal-type: proposal-type,
        title: title,
        description: description,
        target-member: target-member,
        parameter-change: parameter-change,
        new-value: new-value,
        treasury-amount: treasury-amount,
        creation-time: burn-block-height,
        voting-deadline: voting-deadline,
        status: "active",
        votes-for: u0,
        votes-against: u0,
        total-voting-power: u0
      })
      
      ;; Update proposer stats
      (let ((member-data (unwrap-panic (map-get? members tx-sender))))
        (map-set members tx-sender (merge member-data {
          projects-proposed: (+ (get projects-proposed member-data) u1),
          last-activity: burn-block-height
        }))
      )
      
      (ok proposal-id)
    )
  )
)

;; Vote on governance proposal
(define-public (vote-on-governance-proposal (proposal-id uint) (support bool))
  (begin
    (asserts! (is-some (map-get? members tx-sender)) ERR-MEMBER-NOT-FOUND)
    (asserts! (is-none (map-get? governance-votes { proposal-id: proposal-id, voter: tx-sender })) ERR-INVALID-GOVERNANCE-ACTION)
    
    (let ((proposal-data (map-get? governance-proposals proposal-id)))
      (asserts! (is-some proposal-data) ERR-PROPOSAL-NOT-FOUND)
      
      (let ((proposal (unwrap-panic proposal-data))
            (voting-power (calculate-voting-power tx-sender)))
        
        (asserts! (>= voting-power MIN-VOTING-POWER) ERR-INSUFFICIENT-REPUTATION)
        (asserts! (is-eq (get status proposal) "active") ERR-INVALID-GOVERNANCE-ACTION)
        (asserts! (< burn-block-height (get voting-deadline proposal)) ERR-INVALID-GOVERNANCE-ACTION)
        
        ;; Record vote
        (map-set governance-votes { proposal-id: proposal-id, voter: tx-sender } {
          vote: support,
          voting-power: voting-power,
          vote-time: burn-block-height
        })
        
        ;; Update proposal vote counts
        (let ((new-votes-for (if support (+ (get votes-for proposal) voting-power) (get votes-for proposal)))
              (new-votes-against (if support (get votes-against proposal) (+ (get votes-against proposal) voting-power)))
              (new-total-power (+ (get total-voting-power proposal) voting-power)))
          
          (map-set governance-proposals proposal-id (merge proposal {
            votes-for: new-votes-for,
            votes-against: new-votes-against,
            total-voting-power: new-total-power
          }))
        )
        
        ;; Update member vote count
        (let ((member-data (unwrap-panic (map-get? members tx-sender))))
          (map-set members tx-sender (merge member-data {
            votes-cast: (+ (get votes-cast member-data) u1),
            last-activity: burn-block-height
          }))
        )
        
        (ok true)
      )
    )
  )
)

;; Execute governance proposal after voting period
(define-public (execute-governance-proposal (proposal-id uint))
  (let ((proposal-data (map-get? governance-proposals proposal-id)))
    (asserts! (is-some proposal-data) ERR-PROPOSAL-NOT-FOUND)
    
    (let ((proposal (unwrap-panic proposal-data)))
      (asserts! (is-eq (get status proposal) "active") ERR-INVALID-GOVERNANCE-ACTION)
      (asserts! (>= burn-block-height (get voting-deadline proposal)) ERR-INVALID-GOVERNANCE-ACTION)
      
      (let ((passed (> (get votes-for proposal) (get votes-against proposal))))
        (map-set governance-proposals proposal-id (merge proposal {
          status: (if passed "passed" "rejected")
        }))
        
        (ok passed)
      )
    )
  )
)

;; Claim rewards based on contribution and activity
(define-public (claim-activity-rewards (reward-type (string-ascii 20)))
  (begin
    (asserts! (is-some (map-get? members tx-sender)) ERR-MEMBER-NOT-FOUND)
    
    (let ((member-data (unwrap-panic (map-get? members tx-sender)))
          (claim-key { member: tx-sender, reward-type: reward-type })
          (current-period (/ burn-block-height u1440))) ;; ~10 day periods
      
      ;; Check if already claimed for this period
      (let ((existing-claim (map-get? reward-claims claim-key)))
        (if (is-some existing-claim)
            (asserts! (not (is-eq (get claim-period (unwrap-panic existing-claim)) current-period)) ERR-REWARD-ALREADY-CLAIMED)
            true
        )
      )
      
      ;; Calculate reward based on activity and reputation
      (let ((reward-amount (/ (get reputation-score member-data) u5)))
        (asserts! (> reward-amount u0) ERR-INVALID-REWARD-CLAIM)
        
        ;; Record reward claim
        (map-set reward-claims claim-key {
          amount: reward-amount,
          claim-time: burn-block-height,
          claim-period: current-period
        })
        
        ;; Update member tokens
        (map-set members tx-sender (merge member-data {
          governance-tokens: (+ (get governance-tokens member-data) reward-amount),
          last-activity: burn-block-height
        }))
        
        (ok reward-amount)
      )
    )
  )
)

;; Read-only Functions

;; Get member information
(define-read-only (get-member (member principal))
  (map-get? members member)
)

;; Get governance proposal details
(define-read-only (get-governance-proposal (proposal-id uint))
  (map-get? governance-proposals proposal-id)
)

;; Get governance vote
(define-read-only (get-governance-vote (proposal-id uint) (voter principal))
  (map-get? governance-votes { proposal-id: proposal-id, voter: voter })
)

;; Get reward claim information
(define-read-only (get-reward-claim (member principal) (reward-type (string-ascii 20)))
  (map-get? reward-claims { member: member, reward-type: reward-type })
)

;; Get DAO statistics
(define-read-only (get-dao-stats)
  {
    total-members: (var-get total-members),
    total-proposals: (- (var-get governance-proposal-counter) u1),
    total-tokens-distributed: (var-get total-tokens-distributed),
    reward-pool-balance: (var-get reward-pool-balance)
  }
)

;; Get member voting power
(define-read-only (get-voting-power (member principal))
  (calculate-voting-power member)
)

;; Check if member can create proposals
(define-read-only (can-member-create-proposal (member principal))
  (can-create-proposal member)
)

