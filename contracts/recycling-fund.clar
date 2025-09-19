;; Recycling Fund Core - Community Waste Management Fund Pool
;; Main contract for pooling funds and managing recycling project funding

;; Constants
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-PROJECT-NOT-FOUND (err u101))
(define-constant ERR-INSUFFICIENT-FUNDS (err u102))
(define-constant ERR-PROJECT-ALREADY-FUNDED (err u103))
(define-constant ERR-INVALID-AMOUNT (err u104))
(define-constant ERR-PROJECT-NOT-APPROVED (err u105))
(define-constant ERR-VOTING-PERIOD-ENDED (err u106))
(define-constant ERR-ALREADY-VOTED (err u107))
(define-constant ERR-MILESTONE-NOT-FOUND (err u108))
(define-constant ERR-INVALID-STATUS (err u109))

(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-PROJECT-FUNDING u1000)
(define-constant VOTING-PERIOD u144) ;; ~1 day in blocks
(define-constant MIN-VOTES-REQUIRED u3)
(define-constant CONTRIBUTION-REWARD u10) ;; Tokens per 100 STX contributed

;; Data Variables
(define-data-var project-id-counter uint u1)
(define-data-var total-fund-pool uint u0)
(define-data-var total-projects-funded uint u0)
(define-data-var total-contributors uint u0)

;; Data Maps

;; Community fund contributions
(define-map contributions
  principal
  {
    total-contributed: uint,
    contribution-count: uint,
    first-contribution: uint,
    rewards-earned: uint,
    active-contributor: bool
  }
)

;; Recycling project proposals
(define-map projects
  uint ;; project-id
  {
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    funding-goal: uint,
    current-funding: uint,
    project-type: (string-ascii 30), ;; "infrastructure", "technology", "education"
    location: (string-ascii 50),
    expected-impact: uint, ;; estimated tons of waste diverted annually
    creation-time: uint,
    voting-deadline: uint,
    status: (string-ascii 20), ;; "voting", "approved", "rejected", "funded", "completed"
    votes-for: uint,
    votes-against: uint,
    total-voters: uint,
    milestone-count: uint
  }
)

;; Project voting records
(define-map project-votes
  { project-id: uint, voter: principal }
  {
    vote: bool, ;; true = support, false = oppose
    vote-time: uint,
    vote-weight: uint ;; based on contribution history
  }
)

;; Project milestones for phased funding
(define-map project-milestones
  { project-id: uint, milestone-id: uint }
  {
    description: (string-ascii 200),
    funding-amount: uint,
    target-date: uint,
    completion-verified: bool,
    verifier: (optional principal),
    actual-impact: uint
  }
)

;; Fund allocation tracking
(define-map fund-allocations
  uint ;; project-id
  {
    total-allocated: uint,
    amount-disbursed: uint,
    disbursement-count: uint,
    allocation-date: uint
  }
)

;; Impact tracking for completed projects
(define-map impact-records
  uint ;; project-id
  {
    waste-diverted: uint, ;; tons of waste diverted
    energy-saved: uint, ;; kwh saved through recycling
    carbon-reduced: uint, ;; kg CO2 emissions prevented
    community-engagement: uint, ;; number of participants
    verification-date: uint
  }
)

;; Private Functions

;; Generate next project ID
(define-private (get-next-project-id)
  (let ((current-id (var-get project-id-counter)))
    (var-set project-id-counter (+ current-id u1))
    current-id
  )
)

;; Calculate voting weight based on contribution history
(define-private (calculate-vote-weight (voter principal))
  (let ((contributor-data (map-get? contributions voter)))
    (if (is-some contributor-data)
        (let ((contrib (unwrap-panic contributor-data)))
          (if (get active-contributor contrib)
              (+ u1 (/ (get total-contributed contrib) u1000))
              u1
          )
        )
        u1
    )
  )
)

;; Check if project voting period is still active
(define-private (is-voting-active (project-id uint))
  (let ((project-data (map-get? projects project-id)))
    (if (is-some project-data)
        (let ((project (unwrap-panic project-data)))
          (and (is-eq (get status project) "voting")
               (< burn-block-height (get voting-deadline project))
          )
        )
        false
    )
  )
)

;; Calculate project approval based on votes
(define-private (is-project-approved (votes-for uint) (votes-against uint) (total-voters uint))
  (and (>= total-voters MIN-VOTES-REQUIRED)
       (> votes-for votes-against)
       (> votes-for (/ total-voters u2)) ;; More than 50% support
  )
)

;; Public Functions

;; Contribute funds to the community recycling pool
(define-public (contribute-funds (amount uint))
  (begin
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Transfer STX to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update contributor record
    (let ((current-contrib (default-to 
                            { total-contributed: u0, contribution-count: u0, first-contribution: u0, rewards-earned: u0, active-contributor: false }
                            (map-get? contributions tx-sender))))
      (let ((is-new-contributor (is-eq (get contribution-count current-contrib) u0)))
        (map-set contributions tx-sender {
          total-contributed: (+ (get total-contributed current-contrib) amount),
          contribution-count: (+ (get contribution-count current-contrib) u1),
          first-contribution: (if is-new-contributor burn-block-height (get first-contribution current-contrib)),
          rewards-earned: (+ (get rewards-earned current-contrib) (/ (* amount CONTRIBUTION-REWARD) u100)),
          active-contributor: true
        })
        
        ;; Update global counters
        (var-set total-fund-pool (+ (var-get total-fund-pool) amount))
        (if is-new-contributor
            (var-set total-contributors (+ (var-get total-contributors) u1))
            true
        )
      )
    )
    
    (ok amount)
  )
)

;; Create a new recycling project proposal
(define-public (create-project 
  (title (string-ascii 100))
  (description (string-ascii 500))
  (funding-goal uint)
  (project-type (string-ascii 30))
  (location (string-ascii 50))
  (expected-impact uint)
)
  (begin
    (asserts! (> (len title) u0) ERR-INVALID-AMOUNT)
    (asserts! (> funding-goal MIN-PROJECT-FUNDING) ERR-INVALID-AMOUNT)
    (asserts! (> expected-impact u0) ERR-INVALID-AMOUNT)
    
    ;; Check if proposer has contributed to fund
    (asserts! (is-some (map-get? contributions tx-sender)) ERR-UNAUTHORIZED)
    
    (let ((project-id (get-next-project-id))
          (voting-deadline (+ burn-block-height VOTING-PERIOD)))
      
      (map-set projects project-id {
        proposer: tx-sender,
        title: title,
        description: description,
        funding-goal: funding-goal,
        current-funding: u0,
        project-type: project-type,
        location: location,
        expected-impact: expected-impact,
        creation-time: burn-block-height,
        voting-deadline: voting-deadline,
        status: "voting",
        votes-for: u0,
        votes-against: u0,
        total-voters: u0,
        milestone-count: u0
      })
      
      (ok project-id)
    )
  )
)

;; Vote on a project proposal
(define-public (vote-on-project (project-id uint) (support bool))
  (begin
    (asserts! (is-voting-active project-id) ERR-VOTING-PERIOD-ENDED)
    (asserts! (is-none (map-get? project-votes { project-id: project-id, voter: tx-sender })) ERR-ALREADY-VOTED)
    (asserts! (is-some (map-get? contributions tx-sender)) ERR-UNAUTHORIZED)
    
    (let ((vote-weight (calculate-vote-weight tx-sender))
          (project-data (unwrap-panic (map-get? projects project-id))))
      
      ;; Record the vote
      (map-set project-votes { project-id: project-id, voter: tx-sender } {
        vote: support,
        vote-time: burn-block-height,
        vote-weight: vote-weight
      })
      
      ;; Update project vote counts
      (let ((new-votes-for (if support (+ (get votes-for project-data) vote-weight) (get votes-for project-data)))
            (new-votes-against (if support (get votes-against project-data) (+ (get votes-against project-data) vote-weight)))
            (new-total-voters (+ (get total-voters project-data) u1)))
        
        (map-set projects project-id (merge project-data {
          votes-for: new-votes-for,
          votes-against: new-votes-against,
          total-voters: new-total-voters
        }))
      )
      
      (ok true)
    )
  )
)

;; Finalize project voting and determine approval
(define-public (finalize-project-voting (project-id uint))
  (let ((project-data (map-get? projects project-id)))
    (asserts! (is-some project-data) ERR-PROJECT-NOT-FOUND)
    
    (let ((project (unwrap-panic project-data)))
      (asserts! (is-eq (get status project) "voting") ERR-INVALID-STATUS)
      (asserts! (>= burn-block-height (get voting-deadline project)) ERR-VOTING-PERIOD-ENDED)
      
      (let ((approved (is-project-approved (get votes-for project) (get votes-against project) (get total-voters project))))
        (map-set projects project-id (merge project {
          status: (if approved "approved" "rejected")
        }))
        
        (ok approved)
      )
    )
  )
)

;; Fund an approved project
(define-public (fund-project (project-id uint))
  (let ((project-data (map-get? projects project-id)))
    (asserts! (is-some project-data) ERR-PROJECT-NOT-FOUND)
    
    (let ((project (unwrap-panic project-data)))
      (asserts! (is-eq (get status project) "approved") ERR-PROJECT-NOT-APPROVED)
      (asserts! (>= (var-get total-fund-pool) (get funding-goal project)) ERR-INSUFFICIENT-FUNDS)
      
      ;; Transfer funds to project proposer
      (try! (as-contract (stx-transfer? (get funding-goal project) tx-sender (get proposer project))))
      
      ;; Update project status and fund allocation
      (map-set projects project-id (merge project {
        status: "funded",
        current-funding: (get funding-goal project)
      }))
      
      (map-set fund-allocations project-id {
        total-allocated: (get funding-goal project),
        amount-disbursed: (get funding-goal project),
        disbursement-count: u1,
        allocation-date: burn-block-height
      })
      
      ;; Update global counters
      (var-set total-fund-pool (- (var-get total-fund-pool) (get funding-goal project)))
      (var-set total-projects-funded (+ (var-get total-projects-funded) u1))
      
      (ok true)
    )
  )
)

;; Verify project impact and mark as completed
(define-public (verify-project-impact 
  (project-id uint)
  (waste-diverted uint)
  (energy-saved uint)
  (carbon-reduced uint)
  (community-engagement uint)
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED) ;; For now, only owner can verify
    
    (let ((project-data (map-get? projects project-id)))
      (asserts! (is-some project-data) ERR-PROJECT-NOT-FOUND)
      (asserts! (is-eq (get status (unwrap-panic project-data)) "funded") ERR-INVALID-STATUS)
      
      ;; Record impact metrics
      (map-set impact-records project-id {
        waste-diverted: waste-diverted,
        energy-saved: energy-saved,
        carbon-reduced: carbon-reduced,
        community-engagement: community-engagement,
        verification-date: burn-block-height
      })
      
      ;; Update project status
      (map-set projects project-id (merge (unwrap-panic project-data) { status: "completed" }))
      
      (ok true)
    )
  )
)

;; Read-only Functions

;; Get project details
(define-read-only (get-project (project-id uint))
  (map-get? projects project-id)
)

;; Get contributor information
(define-read-only (get-contributor (contributor principal))
  (map-get? contributions contributor)
)

;; Get project vote
(define-read-only (get-project-vote (project-id uint) (voter principal))
  (map-get? project-votes { project-id: project-id, voter: voter })
)

;; Get fund allocation details
(define-read-only (get-fund-allocation (project-id uint))
  (map-get? fund-allocations project-id)
)

;; Get project impact record
(define-read-only (get-impact-record (project-id uint))
  (map-get? impact-records project-id)
)

;; Get fund pool statistics
(define-read-only (get-fund-stats)
  {
    total-fund-pool: (var-get total-fund-pool),
    total-projects-funded: (var-get total-projects-funded),
    total-contributors: (var-get total-contributors),
    total-projects-created: (- (var-get project-id-counter) u1)
  }
)

;; Check if user can vote on project
(define-read-only (can-vote-on-project (project-id uint) (voter principal))
  (and (is-voting-active project-id)
       (is-some (map-get? contributions voter))
       (is-none (map-get? project-votes { project-id: project-id, voter: voter }))
  )
)

