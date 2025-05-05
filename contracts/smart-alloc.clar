;; Title: SmartAlloc - Automated Portfolio Management Protocol

;; SUMMARY:
;; SmartAlloc is a decentralized portfolio management protocol built on Stacks
;; that enables automated allocation and rebalancing of digital assets with
;; Bitcoin-native security guarantees.

;; DESCRIPTION:
;; This protocol allows users to create customized portfolios with target
;; allocations across multiple tokens. It provides functionality for 
;; portfolio creation, allocation management, and automated rebalancing,
;; all secured by Bitcoin's finality through the Stacks consensus mechanism.

;; ERROR CODES

(define-constant ERR-NOT-AUTHORIZED (err u100))        ;; Unauthorized access attempt
(define-constant ERR-INVALID-PORTFOLIO (err u101))     ;; Portfolio doesn't exist or is invalid
(define-constant ERR-INSUFFICIENT-BALANCE (err u102))  ;; Insufficient funds for operation
(define-constant ERR-INVALID-TOKEN (err u103))         ;; Invalid token address provided
(define-constant ERR-REBALANCE-FAILED (err u104))      ;; Portfolio rebalancing operation failed
(define-constant ERR-PORTFOLIO-EXISTS (err u105))      ;; Portfolio already exists
(define-constant ERR-INVALID-PERCENTAGE (err u106))    ;; Invalid allocation percentage
(define-constant ERR-MAX-TOKENS-EXCEEDED (err u107))   ;; Exceeded maximum allowed tokens
(define-constant ERR-LENGTH-MISMATCH (err u108))       ;; Mismatch in input array lengths
(define-constant ERR-USER-STORAGE-FAILED (err u109))   ;; Failed to update user storage
(define-constant ERR-INVALID-TOKEN-ID (err u110))      ;; Invalid token ID in portfolio

;; PROTOCOL CONFIGURATION

(define-data-var protocol-owner principal tx-sender)
(define-data-var portfolio-counter uint u0)
(define-data-var protocol-fee uint u25)                ;; 0.25% in basis points

;; PROTOCOL CONSTANTS

(define-constant MAX-TOKENS-PER-PORTFOLIO u10)
(define-constant BASIS-POINTS u10000)                  ;; 100% = 10000 basis points

;; DATA STRUCTURES

(define-map Portfolios
    uint                                               ;; portfolio-id
    {
        owner: principal,
        created-at: uint,
        last-rebalanced: uint,
        total-value: uint,
        active: bool,
        token-count: uint
    }
)

(define-map PortfolioAssets
    {portfolio-id: uint, token-id: uint}
    {
        target-percentage: uint,
        current-amount: uint,
        token-address: principal
    }
)

(define-map UserPortfolios
    principal
    (list 20 uint)
)

;; READ-ONLY FUNCTIONS

;; Retrieves portfolio details by ID
(define-read-only (get-portfolio (portfolio-id uint))
    (map-get? Portfolios portfolio-id)
)

;; Retrieves specific asset details within a portfolio
(define-read-only (get-portfolio-asset (portfolio-id uint) (token-id uint))
    (map-get? PortfolioAssets {portfolio-id: portfolio-id, token-id: token-id})
)

;; Returns list of portfolio IDs owned by a user
(define-read-only (get-user-portfolios (user principal))
    (default-to (list) (map-get? UserPortfolios user))
)

;; Calculates rebalancing requirements for a portfolio
(define-read-only (calculate-rebalance-amounts (portfolio-id uint))
    (let (
        (portfolio (unwrap! (get-portfolio portfolio-id) ERR-INVALID-PORTFOLIO))
        (total-value (get total-value portfolio))
    )
    (ok {
        portfolio-id: portfolio-id,
        total-value: total-value,
        needs-rebalance: (> (- block-height (get last-rebalanced portfolio)) u144)
    }))
)

;; PRIVATE FUNCTIONS

;; Validates token ID within portfolio constraints
(define-private (validate-token-id (portfolio-id uint) (token-id uint))
    (let (
        (portfolio (unwrap! (get-portfolio portfolio-id) false))
    )
    (and 
        (< token-id MAX-TOKENS-PER-PORTFOLIO)
        (< token-id (get token-count portfolio))
        true
    ))
)

;; Validates percentage is within valid range (0-10000 basis points)
(define-private (validate-percentage (percentage uint))
    (and (>= percentage u0) (<= percentage BASIS-POINTS))
)

;; Validates sum of portfolio percentages
(define-private (validate-portfolio-percentages (percentages (list 10 uint)))
    (let (
        (total (fold + percentages u0))
    )
    (and 
        ;; Check if total equals 100% (10000 basis points)
        (is-eq total BASIS-POINTS)
        ;; Check if each percentage is valid
        (fold and 
            (map validate-percentage percentages)
            true)
    ))
)	

;; Helper function for percentage validation
(define-private (check-percentage-sum (current-percentage uint) (valid bool))
    (and valid (validate-percentage current-percentage))
)

;; Adds portfolio ID to user's portfolio list
(define-private (add-to-user-portfolios (user principal) (portfolio-id uint))
    (let (
        (current-portfolios (get-user-portfolios user))
        (new-portfolios (unwrap! (as-max-len? (append current-portfolios portfolio-id) u20) ERR-USER-STORAGE-FAILED))
    )
    (map-set UserPortfolios user new-portfolios)
    (ok true))
)

;; Initializes a new portfolio asset
(define-private (initialize-portfolio-asset (index uint) (token principal) (percentage uint) (portfolio-id uint))
    (if (>= percentage u0)
        (begin
            (map-set PortfolioAssets
                {portfolio-id: portfolio-id, token-id: index}
                {
                    target-percentage: percentage,
                    current-amount: u0,
                    token-address: token
                }
            )
            (ok true))
        ERR-INVALID-TOKEN
    )
)

;; Recursive function to initialize remaining tokens in a portfolio
(define-private (initialize-remaining-tokens 
    (portfolio-id uint) 
    (tokens (list 10 principal)) 
    (percentages (list 10 uint))
    (start-index uint))
    (let (
        (token-count (len tokens))
    )
    (if (>= start-index token-count)
        (ok true)
        (begin
            (try! (initialize-portfolio-asset
                start-index
                (unwrap! (element-at tokens start-index) ERR-INVALID-TOKEN)
                (unwrap! (element-at percentages start-index) ERR-INVALID-PERCENTAGE)
                portfolio-id))
            (initialize-remaining-tokens portfolio-id tokens percentages (+ start-index u1)))))
)

;; Non-recursive approach to initialize additional tokens
(define-private (initialize-additional-tokens 
    (portfolio-id uint) 
    (tokens (list 10 principal)) 
    (percentages (list 10 uint))
    (start-index uint)
    (count uint))
    (begin
        (if (and (> count u0) (< start-index (len tokens)))
            (begin
                (try! (initialize-portfolio-asset
                    start-index
                    (unwrap! (element-at tokens start-index) ERR-INVALID-TOKEN)
                    (unwrap! (element-at percentages start-index) ERR-INVALID-PERCENTAGE)
                    portfolio-id))
                (initialize-additional-tokens 
                    portfolio-id 
                    tokens 
                    percentages 
                    (+ start-index u1) 
                    (- count u1)))
            (ok true)))
)

;; PUBLIC FUNCTIONS

;; Creates a new portfolio with specified tokens and allocations
(define-public (create-portfolio (initial-tokens (list 10 principal)) (percentages (list 10 uint)))
    (let (
        (portfolio-id (+ (var-get portfolio-counter) u1))
        (token-count (len initial-tokens))
        (percentage-count (len percentages))
    )
    (asserts! (<= token-count MAX-TOKENS-PER-PORTFOLIO) ERR-MAX-TOKENS-EXCEEDED)
    (asserts! (is-eq token-count percentage-count) ERR-LENGTH-MISMATCH)
    (asserts! (validate-portfolio-percentages percentages) ERR-INVALID-PERCENTAGE)
    (asserts! (>= token-count u2) ERR-INVALID-PORTFOLIO) ;; Ensure at least 2 tokens
    
    ;; Create portfolio
    (map-set Portfolios portfolio-id
        {
            owner: tx-sender,
            created-at: block-height,
            last-rebalanced: block-height,
            total-value: u0,
            active: true,
            token-count: token-count
        }
    )
    
    ;; Initialize first two tokens (required minimum)
    (try! (initialize-portfolio-asset 
        u0 
        (unwrap! (element-at initial-tokens u0) ERR-INVALID-TOKEN)
        (unwrap! (element-at percentages u0) ERR-INVALID-PERCENTAGE)
        portfolio-id))
    
    (try! (initialize-portfolio-asset 
        u1
        (unwrap! (element-at initial-tokens u1) ERR-INVALID-TOKEN)
        (unwrap! (element-at percentages u1) ERR-INVALID-PERCENTAGE)
        portfolio-id))
    
    ;; Initialize remaining tokens if any (non-recursive approach)
    (let ((remaining-count (- token-count u2)))
        (if (> remaining-count u0)
            (try! (initialize-additional-tokens portfolio-id initial-tokens percentages u2 remaining-count))
            (ok true)))
    
    ;; Update user's portfolio list
    (try! (add-to-user-portfolios tx-sender portfolio-id))
    
    ;; Increment counter
    (var-set portfolio-counter portfolio-id)
    (ok portfolio-id))
)